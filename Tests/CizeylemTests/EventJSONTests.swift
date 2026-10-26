import XCTest
@testable import Cizeylem

final class EventJSONTests: XCTestCase {
    private func decode(_ text: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(obj as? [String: Any])
    }

    private func event(
        name: String = "cz_app_opened",
        props: [String: Any?]? = nil,
        ops: PropertyOps = PropertyOps(),
        userId: String? = nil,
        context: [String: Any?] = ["platform": "ios"]
    ) -> String {
        EventJSON.event(
            name: name, distinctId: "d-1", time: 1_760_000_000_123, insertId: "i-1",
            sessionId: "1760000000000", props: props, ops: ops, userId: userId, context: context)
    }

    func testZorunluAlanlarYazilir() throws {
        let o = try decode(event())
        XCTAssertEqual(o["event"] as? String, "cz_app_opened")
        XCTAssertEqual(o["distinct_id"] as? String, "d-1")
        XCTAssertEqual((o["time"] as? NSNumber)?.int64Value, 1_760_000_000_123)
        XCTAssertEqual(o["insert_id"] as? String, "i-1")
        XCTAssertEqual(o["session_id"] as? String, "1760000000000", "session_id string olmalı")
        XCTAssertEqual((o["context"] as? [String: Any])?["platform"] as? String, "ios")
        XCTAssertEqual(Set(o.keys), ["event", "distinct_id", "time", "insert_id", "session_id", "context"])
    }

    func testBosPropsVeOperasyonlarGovdeyeYazilmaz() throws {
        let o = try decode(event(
            props: [:],
            ops: PropertyOps(set: [:], setOnce: [:], unset: [], add: [:]),
            userId: ""))
        for key in ["props", "$set", "$set_once", "$unset", "$add", "user_id"] {
            XCTAssertNil(o[key], "\(key) boş ama yazıldı")
        }
    }

    func testNilAlanlarGovdeyeYazilmaz() throws {
        let o = try decode(event(props: nil, ops: PropertyOps(), userId: nil))
        XCTAssertEqual(Set(o.keys), ["event", "distinct_id", "time", "insert_id", "session_id", "context"])
    }

    func testBosContextHerZamanYazilir() throws {
        let o = try decode(event(context: [:]))
        let ctx = try XCTUnwrap(o["context"] as? [String: Any])
        XCTAssertTrue(ctx.isEmpty)
    }

    func testDoluAlanlarYazilir() throws {
        let o = try decode(event(
            props: ["plan": "pro"],
            ops: PropertyOps(set: ["a": 1], setOnce: ["b": "x"], unset: ["c"], add: ["n": 2]),
            userId: "u-9"))
        XCTAssertEqual((o["props"] as? [String: Any])?["plan"] as? String, "pro")
        XCTAssertEqual((o["$set"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual((o["$set_once"] as? [String: Any])?["b"] as? String, "x")
        XCTAssertEqual(o["$unset"] as? [String], ["c"])
        XCTAssertEqual((o["$add"] as? [String: Any])?["n"] as? Int, 2)
        XCTAssertEqual(o["user_id"] as? String, "u-9")
    }

    func testIdentifyGovdesindeUserIdBulunur() throws {
        let o = try decode(event(name: "$identify", userId: "user-42"))
        XCTAssertEqual(o["event"] as? String, "$identify")
        XCTAssertEqual(o["user_id"] as? String, "user-42")
        XCTAssertEqual(o["distinct_id"] as? String, "d-1")
    }

    func testAcikNilKorunurNSNullOlarak() throws {
        let o = try decode(event(props: ["a": nil, "b": 1]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), ["a", "b"], "açık null anahtarı silinmemeli")
        XCTAssertTrue(props["a"] is NSNull)
    }

    func testAnyIcindekiIcIceOptionalDaNullOlur() throws {
        let inner: Int? = nil
        let wrapped: Any = inner as Any
        let o = try decode(event(props: ["x": wrapped]))
        XCTAssertTrue((o["props"] as? [String: Any])?["x"] is NSNull)
    }

    func testIcIceMapVeDizilerKorunur() throws {
        let o = try decode(event(props: [
            "m": ["k": ["deep": [1, "two", ["three": 3.5]]]] as [String: Any],
            "arr": [["a": 1], ["b": nil as Any?]] as [Any],
        ]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        let deep = try XCTUnwrap(((props["m"] as? [String: Any])?["k"] as? [String: Any])?["deep"] as? [Any])
        XCTAssertEqual(deep[0] as? Int, 1)
        XCTAssertEqual(deep[1] as? String, "two")
        XCTAssertEqual((deep[2] as? [String: Any])?["three"] as? Double, 3.5)
        let arr = try XCTUnwrap(props["arr"] as? [Any])
        XCTAssertEqual((arr[0] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertTrue((arr[1] as? [String: Any])?["b"] is NSNull)
    }

    func testNaNVeInfinityEventiDusurmezNullYazilir() throws {
        let o = try decode(event(
            props: [
                "nan": Double.nan, "inf": Double.infinity, "ninf": -Double.infinity,
                "f": Float.nan, "ok": 1.5,
                "nested": ["x": Double.nan, "list": [Double.infinity, 2.0]] as [String: Any],
                "ns": NSNumber(value: Double.nan),
            ],
            ops: PropertyOps(add: ["n": Double.nan])))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        for k in ["nan", "inf", "ninf", "f", "ns"] { XCTAssertTrue(props[k] is NSNull, k) }
        XCTAssertEqual(props["ok"] as? Double, 1.5)
        let nested = try XCTUnwrap(props["nested"] as? [String: Any])
        XCTAssertTrue(nested["x"] is NSNull)
        let list = try XCTUnwrap(nested["list"] as? [Any])
        XCTAssertTrue(list[0] is NSNull)
        XCTAssertEqual(list[1] as? Double, 2.0)
        XCTAssertTrue((o["$add"] as? [String: Any])?["n"] is NSNull)
        XCTAssertEqual(o["event"] as? String, "cz_app_opened", "event düşmemeli")
    }

    func testDesteklenmeyenTipNullOlurEventDusmez() throws {
        let o = try decode(event(props: ["d": Date(), "s": "ok"]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        XCTAssertTrue(props["d"] is NSNull)
        XCTAssertEqual(props["s"] as? String, "ok")
    }

    func testSarilmisOptionalDegerlerAcilir() throws {
        let nanOpt: Double? = .nan
        let five: Int? = 5
        let none: String? = nil
        let o = try decode(event(props: ["nan": nanOpt as Any, "five": five as Any, "none": none as Any]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        XCTAssertTrue(props["nan"] is NSNull)
        XCTAssertEqual(props["five"] as? Int, 5)
        XCTAssertTrue(props["none"] is NSNull)
    }

    func testNSNumberBoolVeSayiTipiniKorur() throws {
        let o = try decode(event(props: ["t": NSNumber(value: true), "n": NSNumber(value: 7), "d": NSNumber(value: 2.5)]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        XCTAssertEqual(CFGetTypeID(props["t"] as CFTypeRef), CFBooleanGetTypeID())
        XCTAssertEqual(props["n"] as? Int, 7)
        XCTAssertEqual(props["d"] as? Double, 2.5)
    }

    func testBuyukTamsayilarKesinliginiKaybetmez() throws {
        let o = try decode(event(props: ["big": Int64.max, "ubig": UInt64.max]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        XCTAssertEqual((props["big"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertEqual((props["ubig"] as? NSNumber)?.uint64Value, UInt64.max)
    }

    func testBoolSayiyaDonusmez() throws {
        let o = try decode(event(props: ["t": true, "f": false, "one": 1]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        XCTAssertEqual(CFGetTypeID(props["t"] as CFTypeRef), CFBooleanGetTypeID())
        XCTAssertEqual(CFGetTypeID(props["f"] as CFTypeRef), CFBooleanGetTypeID())
        XCTAssertNotEqual(CFGetTypeID(props["one"] as CFTypeRef), CFBooleanGetTypeID())
    }

    func testSatirTekSatirdirYeniSatirKacirilir() {
        let line = event(props: ["t": "a\nb\r\nc", "u": "ünï \u{2028} 😀"])
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        XCTAssertFalse(line.isEmpty)
    }

    func testAnahtarlarunicodeVeEgikCizgiKorunur() throws {
        let o = try decode(event(props: ["a/b": "c/d", "ş": 1]))
        let props = try XCTUnwrap(o["props"] as? [String: Any])
        XCTAssertEqual(props["a/b"] as? String, "c/d")
        XCTAssertEqual(props["ş"] as? Int, 1)
    }

    // MARK: - batch

    func testBatchGovdesiSentAtVeEventsIcerir() throws {
        let l1 = event(name: "a"), l2 = event(name: "b")
        let result = EventJSON.batch(sentAt: 1_760_000_999_000, lines: [l1, l2])
        XCTAssertEqual(result.skipped, 0)
        let o = try decode(result.body)
        XCTAssertEqual(Set(o.keys), ["sent_at", "events"])
        XCTAssertEqual((o["sent_at"] as? NSNumber)?.int64Value, 1_760_000_999_000)
        let events = try XCTUnwrap(o["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["event"] as? String }, ["a", "b"])
        XCTAssertEqual(events[0]["insert_id"] as? String, "i-1", "insert_id aynen taşınır")
    }

    func testBatchSatirlariYenidenKodlarStringOlarakGomMez() throws {
        let result = EventJSON.batch(sentAt: 1, lines: [event()])
        let o = try decode(result.body)
        XCTAssertTrue((o["events"] as? [Any])?.first is [String: Any])
    }

    func testBatchZehirliSatiriAtlarVeSayar() throws {
        let good = event(name: "ok")
        let poison = ["{\"event\":\"yarim", "", "   ", "not json", "[1,2]", "\"str\"", "42", "null", "{}x"]
        let result = EventJSON.batch(sentAt: 1, lines: [poison[0], good, poison[1], poison[2], poison[3],
                                                        poison[4], poison[5], poison[6], poison[7], poison[8]])
        XCTAssertEqual(result.skipped, poison.count)
        let events = try XCTUnwrap(try decode(result.body)["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["event"] as? String, "ok")
    }

    func testBatchSadeceZehirliSatirlarBosEventsDoner() throws {
        let result = EventJSON.batch(sentAt: 1, lines: ["x", "y"])
        XCTAssertEqual(result.skipped, 2)
        let o = try decode(result.body)
        XCTAssertEqual((o["events"] as? [Any])?.count, 0)
    }

    func testBatchBosGirdiBosEvents() throws {
        let result = EventJSON.batch(sentAt: 1, lines: [])
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual((try decode(result.body)["events"] as? [Any])?.count, 0)
    }

    func testBatchSiraKorunur() throws {
        let lines = (0..<20).map { event(name: "e\($0)") }
        let events = try XCTUnwrap(try decode(EventJSON.batch(sentAt: 1, lines: lines).body)["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["event"] as? String }, (0..<20).map { "e\($0)" })
    }
}

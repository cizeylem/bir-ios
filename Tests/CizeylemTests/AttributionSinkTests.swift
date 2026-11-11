import XCTest
@testable import Cizeylem

/// Giden istekleri kaydeden sahte gönderici.
actor RecordingSender: AttributionSending {
    struct Call: Sendable { let path: String; let body: String }
    private(set) var calls: [Call] = []
    private let outcome: Outcome
    init(outcome: Outcome = .ok) { self.outcome = outcome }

    func post(path: String, body: String) async -> (Outcome, retryAfter: Double?) {
        calls.append(Call(path: path, body: body))
        return (outcome, nil)
    }
    func all() -> [Call] { calls }
}

final class AttLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

private func object(_ body: String) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]) ?? [:]
}

/// İKİNCİ SAVUNMA HATTI (Görev 12, karar 2): kimliksiz uca giden gövde, çağıran ne verirse
/// versin, son kapıda süzülür. Bu dosya çağıranın kapısını (`Attribution`) HİÇ kullanmaz:
/// süzme tek başına kilitli olmalı.
final class AttributionBodyTests: XCTestCase {
    func testAnonGovdedenDortKimlikAnahtariAtilir() {
        for key in ["idfa", "device_id", "user_id", "distinct_id"] {
            let body = AttributionBody.anonymous(["adservices_token": "tok", key: "kimlik"])
            let o = object(body)
            XCTAssertNil(o[key], "\(key) anon gövdede olmamalı")
            XCTAssertEqual(o["adservices_token"] as? String, "tok")
        }
    }

    func testAnonGovdeHepsiBirdenGelinceSadeceTokenKalir() {
        let body = AttributionBody.anonymous([
            "adservices_token": "tok", "idfa": "A", "device_id": "B", "user_id": "C", "distinct_id": "D",
        ])
        XCTAssertEqual(Set(object(body).keys), ["adservices_token"])
    }

    func testAnonSuzmeBuyukKucukHarfeVeIcIceAnahtaraDayanir() {
        let body = AttributionBody.anonymous([
            "IDFA": "A", "Device_Id": "B", "nested": ["idfa": "X", "ok": 1] as [String: Any],
        ])
        let o = object(body)
        XCTAssertNil(o["IDFA"])
        XCTAssertNil(o["Device_Id"])
        let nested = o["nested"] as? [String: Any]
        XCTAssertNil(nested?["idfa"])
        XCTAssertEqual(nested?["ok"] as? Int, 1)
    }

    func testAnonSuzmeDiziIcindekiSozluklereDeInler() {
        let body = AttributionBody.anonymous([
            "tok": "t",
            "a": [["idfa": "A", "ok": 1]] as [Any],
            "b": [[["device_id": "B"]]] as [Any],
            "c": [[["x": [["user_id": "U"]] as [Any]]]] as [Any],
            "d": ["düz", 1, ["distinct_id": "D"]] as [Any],
        ])
        XCTAssertFalse(body.contains("idfa"))
        XCTAssertFalse(body.contains("device_id"))
        XCTAssertFalse(body.contains("user_id"))
        XCTAssertFalse(body.contains("distinct_id"))
        let o = object(body)
        XCTAssertEqual(((o["a"] as? [[String: Any]])?.first)?["ok"] as? Int, 1)
        XCTAssertEqual((o["d"] as? [Any])?.first as? String, "düz")
    }

    func testAnonSuzmeYazimVaryantlariniDaAtar() {
        let keys = ["deviceId", "device-id", "DEVICE_ID", "Device Id", " device_id ", "userId", "user-id",
                    "distinctId", "distinct id", "IDFA", "i_d_f_a", "id-fa"]
        for key in keys {
            let o = object(AttributionBody.anonymous([key: "x", "adservices_token": "t"]))
            XCTAssertEqual(Set(o.keys), ["adservices_token"], "'\(key)'")
        }
        // Kimlikle ilgisiz benzer anahtarlar kalır.
        XCTAssertEqual(Set(object(AttributionBody.anonymous(["device_model": "x", "identifier": "y"])).keys),
                       ["device_model", "identifier"])
    }

    func testKimlikliGovdedeIdfaVeAttStatusYalnizCekirdekIzinVerirse() {
        let f: [String: Any] = ["idfa": "A", "att_status": "authorized", "adservices_token": "t",
                                "n": [["IDFA": "B"]] as [Any]]
        let none = object(AttributionBody.identified(f, deviceId: "d"))
        XCTAssertNil(none["idfa"]); XCTAssertNil(none["att_status"])
        XCTAssertFalse(AttributionBody.identified(f, deviceId: "d").contains("\"B\""))
        XCTAssertEqual(none["adservices_token"] as? String, "t")
        let idfaOnly = object(AttributionBody.identified(f, deviceId: "d", allowIdfa: true))
        XCTAssertEqual(idfaOnly["idfa"] as? String, "A"); XCTAssertNil(idfaOnly["att_status"])
        let statusOnly = object(AttributionBody.identified(f, deviceId: "d", allowAttStatus: true))
        XCTAssertNil(statusOnly["idfa"]); XCTAssertEqual(statusOnly["att_status"] as? String, "authorized")
    }

    func testKimlikliGovdeDeviceIdTasir() {
        let body = AttributionBody.identified(["adservices_token": "t", "idfa": "A"], deviceId: "dev-1", allowIdfa: true)
        let o = object(body)
        XCTAssertEqual(o["device_id"] as? String, "dev-1")
        XCTAssertEqual(o["idfa"] as? String, "A")
    }

    func testKimlikliGovdedeCagiranDeviceIdiEzilir() {
        let body = AttributionBody.identified(["device_id": "sahte"], deviceId: "dev-1")
        XCTAssertEqual(object(body)["device_id"] as? String, "dev-1")
    }
}

/// Core üzerinden uçtan uca: rota, yol, gövde ve kapılar.
final class CoreAttributionTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cz-att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "co.cizeylem.test.\(UUID().uuidString)"
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func make(_ sender: RecordingSender, log: AttLogBox = AttLogBox()) -> Core {
        var d = Core.Dependencies()
        d.platform = Platform(
            name: "ios", queueDirectory: root.appendingPathComponent("q"),
            maxEvents: 100, maxBytes: 1_000_000, flushAt: 30)
        d.defaultsSuite = suite
        d.lifecycle = LifecycleLocation(url: root.appendingPathComponent("life"), usesDefaults: false)
        d.amplitudeLibraryDirectory = root.appendingPathComponent("amp")
        d.makeAttributionSender = { _, _ in sender }
        let cfg = Configuration(
            writeKey: "ck_w_test", flushInterval: 0, legacyAmplitude: false, logger: { log.add($0) })
        return Core(config: cfg, deps: d)
    }

    private func combos() -> [Consent] {
        var out: [Consent] = []
        for a in [false, true] { for b in [false, true] { for c in [false, true] {
            out.append(Consent(analytics: a, attribution: b, adSharing: c))
        } } }
        return out
    }

    func testAnonUcHerRizaKombinasyonundaIdfaVeKimlikTasimaz() async {
        for consent in combos() {
            let sender = RecordingSender()
            let core = make(sender)
            await core.start()
            await core.setConsent(consent)
            await core.sendAttribution(.anonymous, [
                "adservices_token": .string("tok"), "idfa": .string("AAAA"), "device_id": .string("d"),
                "user_id": .string("u"), "distinct_id": .string("x"),
            ])
            let calls = await sender.all()
            XCTAssertEqual(calls.count, 1, "\(consent)")
            XCTAssertEqual(calls.first?.path, "/v1/attribution/anon")
            XCTAssertEqual(Set(object(calls.first?.body ?? "").keys), ["adservices_token"], "\(consent)")
        }
    }

    func testKimlikliUcDeviceIdIleVeAyriYoldanGider() async {
        let sender = RecordingSender()
        let core = make(sender)
        await core.start()
        await core.setConsent(Consent(analytics: true, attribution: true))
        await core.sendAttribution(.identified, ["adservices_token": .string("tok")])
        let calls = await sender.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.path, "/v1/attribution")
        let o = object(calls.first?.body ?? "")
        XCTAssertEqual(o["adservices_token"] as? String, "tok")
        let id = await core.distinctId()
        XCTAssertEqual(o["device_id"] as? String, id)
        XCTAssertNotNil(o["device_id"])
    }

    func testKimlikliUcCekirdekRizasiYoksaHicGonderilmezVeKimlikUretilmez() async {
        // Çağıran yanlış rotayı seçse bile çekirdeğin kendi rızası son söz.
        for consent in combos() where !consent.allowsIdentifiedAttribution {
            let sender = RecordingSender()
            let log = AttLogBox()
            let core = make(sender, log: log)
            await core.start()
            await core.setConsent(consent)
            await core.sendAttribution(.identified, ["adservices_token": .string("tok")])
            let calls = await sender.all()
            XCTAssertTrue(calls.isEmpty, "\(consent)")
        }
    }

    /// I2: çağıranın elindeki rıza kopyası eski olabilir; çekirdek kendi rızasına bakar.
    func testKimlikliUcCekirdekAdSharingKapaliysaIdfaVeAttStatusuAtar() async {
        let sender = RecordingSender()
        let core = make(sender)
        await core.start()
        await core.setConsent(Consent(analytics: true, attribution: true, adSharing: false))
        await core.sendAttribution(.identified, [
            "adservices_token": .string("t"), "idfa": .string("AAAA"), "att_status": .string("authorized")])
        let o = object((await sender.all()).first?.body ?? "")
        XCTAssertNil(o["idfa"])
        XCTAssertNil(o["att_status"])
        XCTAssertEqual(o["adservices_token"] as? String, "t")
        XCTAssertNotNil(o["device_id"])
    }

    func testKimlikliUcCekirdekUcRizaAciksaIdfaVeAttStatusGecer() async {
        let sender = RecordingSender()
        let core = make(sender)
        await core.start()
        await core.setConsent(Consent(analytics: true, attribution: true, adSharing: true))
        await core.sendAttribution(.identified, [
            "idfa": .string("AAAA"), "att_status": .string("authorized")])
        let o = object((await sender.all()).first?.body ?? "")
        XCTAssertEqual(o["idfa"] as? String, "AAAA")
        XCTAssertEqual(o["att_status"] as? String, "authorized")
    }

    func testRizasizAnonUcaTokenGider() async {
        let sender = RecordingSender()
        let core = make(sender)
        await core.start()
        await core.sendAttribution(.anonymous, ["adservices_token": .string("tok")])
        let calls = await sender.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.path, "/v1/attribution/anon")
    }

    func testAgHatasiLogaDuserVeFirlatmaz() async {
        let sender = RecordingSender(outcome: .retry)
        let log = AttLogBox()
        let core = make(sender, log: log)
        await core.start()
        await core.sendAttribution(.anonymous, ["adservices_token": .string("tok")])
        XCTAssertEqual(log.all.count, 1)
        XCTAssertTrue((log.all.first ?? "").hasPrefix("[cizeylem] "))
        XCTAssertTrue((log.all.first ?? "").contains("attribution"))
    }

    func testBasariliGonderimLogaYazmaz() async {
        let log = AttLogBox()
        let core = make(RecordingSender(), log: log)
        await core.start()
        await core.sendAttribution(.anonymous, ["adservices_token": .string("tok")])
        XCTAssertTrue(log.all.isEmpty)
    }

    func testSinkRotayiCekirdegeIletir() async {
        let sender = RecordingSender()
        let core = make(sender)
        await core.start()
        await core.setConsent(Consent(analytics: true, attribution: true))
        let sink = CoreAttributionSink { route, fields in await core.sendAttribution(route, fields) }
        await sink.sendAnonymous(["adservices_token": "a", "idfa": "ZZ"])
        await sink.sendIdentified(["adservices_token": "b"])
        let calls = await sender.all()
        XCTAssertEqual(calls.map(\.path), ["/v1/attribution/anon", "/v1/attribution"])
        XCTAssertNil(object(calls.first?.body ?? "")["idfa"])
    }
}

/// `Transport.post` yolu verilen yola yazar ve `/v1/batch` davranışını bozmaz.
final class TransportPostTests: XCTestCase {
    func testPostVerilenYolaBearerIleGider() async {
        await Registry.shared.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        cfg.httpAdditionalHeaders = ["X-Stub": Stub.status(202, headers: [:]).header]
        let t = Transport(endpoint: URL(string: "https://in.example.com/")!, apiKey: "ck_w_x",
                          session: URLSession(configuration: cfg))
        let r = await t.post(path: "/v1/attribution/anon", body: "{\"a\":1}")
        XCTAssertEqual(r.0, .ok)
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].url?.absoluteString, "https://in.example.com/v1/attribution/anon")
        XCTAssertEqual(seen[0].method, "POST")
        XCTAssertEqual(seen[0].headers["Authorization"], "Bearer ck_w_x")
    }
}

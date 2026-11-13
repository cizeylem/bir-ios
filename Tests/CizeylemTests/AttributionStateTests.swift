import XCTest
@testable import Cizeylem

private func json(_ body: String) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]) ?? [:]
}

/// Çekirdek tarafı (SPEC §8.2): kalıcı durum yalnız rızayla, rıza geri alınınca silinir; zarf
/// alanları gövdeye girer; gönderim sonucu doğru eşlenir; 0.3.0'dan yükseltme tanınır.
final class AttributionStateTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cz-ast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "co.cizeylem.test.\(UUID().uuidString)"
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private var lifecycleURL: URL { root.appendingPathComponent("life") }
    private var queueDir: URL { root.appendingPathComponent("q") }

    private func make(_ sender: RecordingSender, now: Double = 1_763_000_000) -> Core {
        var d = Core.Dependencies()
        d.platform = Platform(name: "ios", queueDirectory: queueDir, maxEvents: 100, maxBytes: 1_000_000, flushAt: 30)
        d.defaultsSuite = suite
        d.lifecycle = LifecycleLocation(url: lifecycleURL, usesDefaults: false)
        d.amplitudeLibraryDirectory = root.appendingPathComponent("amp")
        d.makeAttributionSender = { _, _ in sender }
        d.now = { now }
        return Core(config: Configuration(writeKey: "ck_w_test", flushInterval: 0, legacyAmplitude: false), deps: d)
    }

    private let sample = AttributionState(
        pending: true, insertId: "ins-1", firstSignalAtMs: 1_762_000_000_000, sentAttStatus: "denied",
        sentRoute: "identified", attempts: 2)

    func testRizasizDurumYokVeYazilmaz() async {
        let core = make(RecordingSender())
        await core.start()
        let load = await core.loadAttributionState()
        XCTAssertEqual(load, .unavailable)
        let saved = await core.saveAttributionState(sample)
        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueDir.appendingPathComponent("attribution").path),
                       "rızasız kalıcı iz olmamalı")
    }

    func testRizaylaDurumYazilirVeAynenOkunur() async {
        let core = make(RecordingSender())
        await core.start()
        await core.setConsent(Consent(analytics: true))
        let first = await core.loadAttributionState()
        XCTAssertEqual(first, .absent)
        let saved = await core.saveAttributionState(sample)
        XCTAssertTrue(saved)
        // Yeni süreç: aynı dizin.
        let core2 = make(RecordingSender())
        await core2.start()
        let load = await core2.loadAttributionState()
        XCTAssertEqual(load, .present(sample))
        let raw = (try? String(contentsOf: queueDir.appendingPathComponent("attribution"), encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("tok"), "durum dosyası token taşımamalı")
    }

    func testRizaGeriAlininDurumSilinir() async {
        let core = make(RecordingSender())
        await core.start()
        await core.setConsent(Consent(analytics: true))
        await core.saveAttributionState(sample)
        await core.setConsent(Consent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueDir.appendingPathComponent("attribution").path))
        await core.setConsent(Consent(analytics: true))
        let load = await core.loadAttributionState()
        if case .present = load { XCTFail("rıza geri alındıktan sonra eski durum dönmemeli") }
    }

    func testZarfAlanlariGovdeyeGirerCagiraninkiEzilir() async {
        for route in [AttributionRoute.anonymous, .identified] {
            let sender = RecordingSender()
            let core = make(sender, now: 1_763_000_123.456)
            await core.start()
            await core.setConsent(Consent(analytics: true, attribution: true))
            let r = await core.sendAttribution(
                route, ["adservices_token": .string("tok"), "insert_id": .string("sahte"), "time": .string("x")],
                envelope: AttributionEnvelope(insertId: "ins-9", timeMs: 1_762_999_000_000))
            XCTAssertEqual(r, .sent)
            let o = json(await sender.all().first?.body ?? "")
            XCTAssertEqual(o["insert_id"] as? String, "ins-9", "\(route)")
            XCTAssertEqual((o["time"] as? NSNumber)?.int64Value, 1_762_999_000_000, "\(route)")
            XCTAssertEqual((o["sent_at"] as? NSNumber)?.int64Value, 1_763_000_123_456, "\(route)")
            XCTAssertEqual(o["adservices_token"] as? String, "tok")
        }
    }

    func testZarfsizGonderimdeZarfAlaniYok() async {
        let sender = RecordingSender()
        let core = make(sender)
        await core.start()
        await core.sendAttribution(.anonymous, ["adservices_token": .string("tok"), "insert_id": .string("sahte")])
        let o = json(await sender.all().first?.body ?? "")
        XCTAssertNil(o["insert_id"])
        XCTAssertNil(o["sent_at"])
    }

    func testSonucEslemesi() async {
        let table: [(Outcome, AttributionDelivery)] = [
            (.ok, .sent), (.drop, .rejected), (.fatal, .stopped), (.retry, .retryLater), (.split, .retryLater),
        ]
        for (outcome, want) in table {
            let core = make(RecordingSender(outcome: outcome))
            await core.start()
            let got = await core.sendAttribution(.anonymous, ["adservices_token": .string("tok")],
                                                 envelope: AttributionEnvelope(insertId: "i", timeMs: nil))
            XCTAssertEqual(got, want, "\(outcome)")
        }
    }

    func testKimlikliUcRizasizSonraTekrarDenenir() async {
        let sender = RecordingSender()
        let core = make(sender)
        await core.start()
        let got = await core.sendAttribution(.identified, ["adservices_token": .string("tok")],
                                             envelope: AttributionEnvelope(insertId: "i", timeMs: nil))
        XCTAssertEqual(got, .retryLater)
        let calls = await sender.all()
        XCTAssertTrue(calls.isEmpty)
    }
}

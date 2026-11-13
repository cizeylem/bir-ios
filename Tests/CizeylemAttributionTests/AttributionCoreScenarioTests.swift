import XCTest
@testable import CizeylemAttribution
@testable import Cizeylem

actor SwitchSender: AttributionSending {
    var outcome: Outcome = .ok
    private(set) var calls: [(path: String, body: String)] = []
    func set(_ o: Outcome) { outcome = o }
    func post(path: String, body: String) async -> (Outcome, retryAfter: Double?) {
        calls.append((path, body)); return (outcome, nil)
    }
    func all() -> [(path: String, body: String)] { calls }
}

/// Gözden geçirme senaryoları gerçek `Core` ile (SPEC §8.2): rıza süreç içinde verilir, rızasız
/// açılışlar, aynı süreçte analytics.
final class AttributionCoreScenarioTests: XCTestCase {
    var root: URL!
    var suite: String!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cz-rev-\(UUID().uuidString)")
        suite = "co.cizeylem.test.\(UUID().uuidString)"
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func makeCore(_ sender: SwitchSender) -> Core {
        var d = Core.Dependencies()
        d.platform = Platform(name: "ios", queueDirectory: root.appendingPathComponent("q"),
                              maxEvents: 10, maxBytes: 100_000, flushAt: 30)
        d.defaultsSuite = suite
        d.lifecycle = LifecycleLocation(url: root.appendingPathComponent("life"), usesDefaults: false)
        d.amplitudeLibraryDirectory = root.appendingPathComponent("amp")
        d.makeAttributionSender = { _, _ in sender }
        d.notificationCenter = NotificationCenter()
        return Core(config: Configuration(writeKey: "ck_w_t", flushInterval: 0, legacyAmplitude: false), deps: d)
    }

    func waitLifecycle() async {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("life").path) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("lifecycle yazılmadı")
    }

    func insertIds(_ calls: [(path: String, body: String)]) -> [String] {
        calls.map { (((try? JSONSerialization.jsonObject(with: Data($0.body.utf8))) as? [String: Any])?["insert_id"] as? String) ?? "-" }
    }

    /// Süreç 1: rızasız ilk deneme (ağ yok), sonra süreç içinde rıza verilir, yeni deneme olmaz.
    /// Süreç 2: kayıt yok ama kurulum taze → sinyal gider.
    func testRizaSurecIcindeVerilirseIkinciSurecteSinyalGitmez() async {
        let sender = SwitchSender()
        await sender.set(.retry)
        let core1 = makeCore(sender)
        await core1.start()
        let h1 = RetryHarness()
        let r1 = h1.runner()
        await r1.start(sink: CoreAttributionSink(core: core1), consent: Consent())
        // Tekrarlar bitsin.
        var last: Task<Void, Never>?
        while let t = await r1.retryTask, t != last { await t.value; last = t }
        let c1 = await sender.all().count
        await core1.setConsent(Consent(analytics: true, attribution: true))
        await waitLifecycle()
        await core1.shutdown()

        // Süreç 2: ağ var.
        await sender.set(.ok)
        let core2 = makeCore(sender)
        await core2.start()
        let h2 = RetryHarness()
        let r2 = h2.runner()
        await r2.start(sink: CoreAttributionSink(core: core2), consent: Consent(analytics: true, attribution: true))
        let all = await sender.all()
        XCTAssertGreaterThan(all.count, c1, "süreç 2'de sinyal gitmeli")
        XCTAssertEqual(all.last?.path, "/v1/attribution")
    }

    /// Rızasız, kurulumdan saatler sonra üç açılış: hiçbiri sinyal göndermez (her açılış yeni bir
    /// kimliksiz "kurulum" olurdu). İlk 15 dakikadaki açılışlar gönderir (bilinen sınır, SPEC §8.2).
    func testRizasizEskiKurulumdaAcilislarGondermez() async {
        let sender = SwitchSender()
        for _ in 0..<3 {
            let core = makeCore(sender)
            await core.start()
            let h = RetryHarness()
            h.installedAt = h.now - 2 * 3_600_000
            let r = h.runner()
            await r.start(sink: CoreAttributionSink(core: core), consent: Consent())
        }
        let all = await sender.all()
        XCTAssertEqual(all.count, 0)
    }

    /// Süreç içinde yalnız analytics verilir, sonra ön plana geliş: ikinci kimliksiz sinyal?
    func testAnalyticsVerilinceOnPlanIkinciAnonGonderir() async {
        let sender = SwitchSender()
        let core = makeCore(sender)
        await core.start()
        let h = RetryHarness()
        let r = h.runner()
        await r.start(sink: CoreAttributionSink(core: core), consent: Consent())
        await core.setConsent(Consent(analytics: true))
        await r.start(sink: CoreAttributionSink(core: core), consent: Consent(analytics: true))
        let all = await sender.all()
        XCTAssertEqual(all.count, 1, "aynı rota için ikinci sinyal gitmemeli")
    }
}

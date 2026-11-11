import XCTest
@testable import Cizeylem

/// İzleme ucu ayrımı (ITMS-91064). Apple `NSPrivacyTrackingDomains`'teki host'lara ATT izni
/// vermemiş kullanıcıda bağlantıyı keser; bu yüzden YALNIZ IDFA taşıyan gövde izleme ucuna
/// gider, diğer her şey (olaylar, kimliksiz ve IDFA'sız kimlikli attribution) ingest ucuna.
/// Adresi rota değil oluşan gövde belirler.
final class TrackingEndpointTests: XCTestCase {
    /// Taban adresi de kaydeden sahte gönderici.
    actor BaseRecorder {
        struct Call: Sendable { let base: URL; let path: String; let body: String }
        private(set) var calls: [Call] = []
        private(set) var made: [URL] = []
        func record(_ c: Call) { calls.append(c) }
        func made(_ u: URL) { made.append(u) }
        func all() -> [Call] { calls }
        func factories() -> [URL] { made }
    }

    struct Sender: AttributionSending {
        let base: URL
        let recorder: BaseRecorder
        func post(path: String, body: String) async -> (Outcome, retryAfter: Double?) {
            await recorder.record(.init(base: base, path: path, body: body))
            return (.ok, nil)
        }
    }

    private let ingest = URL(string: "https://in.example.com")!
    private let tracking = URL(string: "https://attr.example.com")!
    private let idfa = "11111111-2222-3333-4444-555555555555"
    private var root: URL!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cz-trk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "co.cizeylem.test.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func make(_ recorder: BaseRecorder, trackingEndpoint: URL? = nil) -> Core {
        var d = Core.Dependencies()
        d.platform = Platform(
            name: "ios", queueDirectory: root.appendingPathComponent("q"),
            maxEvents: 100, maxBytes: 1_000_000, flushAt: 30)
        d.defaultsSuite = suite
        d.lifecycle = LifecycleLocation(url: root.appendingPathComponent("life"), usesDefaults: false)
        d.amplitudeLibraryDirectory = root.appendingPathComponent("amp")
        d.makeAttributionSender = { _, base in
            Task { await recorder.made(base) }
            return Sender(base: base, recorder: recorder)
        }
        let cfg = Configuration(
            writeKey: "ck_w_test", endpoint: ingest, trackingEndpoint: trackingEndpoint ?? tracking,
            flushInterval: 0, legacyAmplitude: false)
        return Core(config: cfg, deps: d)
    }

    private func object(_ body: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]) ?? [:]
    }

    private let all = Consent(analytics: true, attribution: true, adSharing: true)

    // MARK: - Varsayılanlar

    func testVarsayilanAdreslerAyriHostlar() {
        XCTAssertEqual(Configuration.defaultEndpoint.host, "in.cizeylem.com")
        XCTAssertEqual(Configuration.defaultTrackingEndpoint.host, "attr.cizeylem.com")
        let c = Configuration(writeKey: "k")
        XCTAssertEqual(c.endpoint, Configuration.defaultEndpoint)
        XCTAssertEqual(c.trackingEndpoint, Configuration.defaultTrackingEndpoint)
    }

    func testVarsayilanFabrikalarDogruHostuSecer() {
        let cfg = Configuration(writeKey: "k", endpoint: ingest, trackingEndpoint: tracking)
        let d = Core.Dependencies()
        // Olaylar her zaman ingest ucuna.
        XCTAssertEqual((d.makeTransport(cfg) as? Transport)?.endpoint, ingest)
        // Attribution göndericisi kendisine verilen tabanı kullanır.
        XCTAssertEqual((d.makeAttributionSender(cfg, tracking) as? Transport)?.endpoint, tracking)
        XCTAssertEqual((d.makeAttributionSender(cfg, ingest) as? Transport)?.endpoint, ingest)
    }

    // MARK: - Yönlendirme

    func testKimliksizAttributionIngestUcunaGider() async {
        let rec = BaseRecorder()
        let core = make(rec)
        await core.start()
        await core.setConsent(all)
        await core.sendAttribution(.anonymous, ["adservices_token": .string("tok"), "idfa": .string(idfa)])
        let calls = await rec.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.base, ingest)
        XCTAssertEqual(calls.first?.path, "/v1/attribution/anon")
        XCTAssertNil(object(calls.first?.body ?? "")["idfa"])
    }

    func testKimlikliIdfasizAttributionIngestUcunaGider() async {
        let rec = BaseRecorder()
        let core = make(rec)
        await core.start()
        await core.setConsent(all)
        await core.sendAttribution(.identified, ["adservices_token": .string("tok"), "att_status": .string("denied")])
        let calls = await rec.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.base, ingest, "IDFA'sız gövde izleme ucuna gitmemeli (ASA verisi kaybolur)")
        XCTAssertEqual(calls.first?.path, "/v1/attribution")
    }

    func testKimlikliIdfaliAttributionIzlemeUcunaGider() async {
        let rec = BaseRecorder()
        let core = make(rec)
        await core.start()
        await core.setConsent(all)
        await core.sendAttribution(.identified, [
            "adservices_token": .string("tok"), "att_status": .string("authorized"), "idfa": .string(idfa),
        ])
        let calls = await rec.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.base, tracking)
        XCTAssertEqual(calls.first?.path, "/v1/attribution")
        XCTAssertEqual(object(calls.first?.body ?? "")["idfa"] as? String, idfa)
    }

    /// Karar rıza bayrağına değil gövdeye göre: çağıran IDFA verse de çekirdek rızası
    /// (`adSharing`) yoksa IDFA gövdeden düşer ve istek ingest ucuna gider.
    func testRizaIdfayiDusururseIngestUcunaGider() async {
        let rec = BaseRecorder()
        let core = make(rec)
        await core.start()
        await core.setConsent(Consent(analytics: true, attribution: true, adSharing: false))
        await core.sendAttribution(.identified, ["adservices_token": .string("tok"), "idfa": .string(idfa)])
        let calls = await rec.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.base, ingest)
        XCTAssertNil(object(calls.first?.body ?? "")["idfa"])
    }

    func testOzelIzlemeUcuVeSondakiEgikCizgi() async {
        let rec = BaseRecorder()
        let custom = URL(string: "https://track.example.org/")!
        let core = make(rec, trackingEndpoint: custom)
        await core.start()
        await core.setConsent(all)
        await core.sendAttribution(.identified, ["idfa": .string(idfa)])
        let calls = await rec.all()
        XCTAssertEqual(calls.first?.base, custom)
    }

    func testGondericiTabanBasinaBirKezKurulur() async {
        let rec = BaseRecorder()
        let core = make(rec)
        await core.start()
        await core.setConsent(all)
        for _ in 0..<3 {
            await core.sendAttribution(.identified, ["idfa": .string(idfa)])
            await core.sendAttribution(.identified, ["adservices_token": .string("tok")])
        }
        let calls = await rec.all()
        XCTAssertEqual(calls.filter { $0.base == tracking }.count, 3)
        XCTAssertEqual(calls.filter { $0.base == ingest }.count, 3)
        // Fabrika kaydı Task ile düşer; bir sonraki actor geçişine kadar bekle.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let made = await rec.factories()
        XCTAssertEqual(made.count, 2, "\(made)")
    }

    // MARK: - IDFA tespiti

    func testCarriesIdfa() {
        XCTAssertTrue(AttributionBody.carriesIdfa(#"{"idfa":"x"}"#))
        XCTAssertTrue(AttributionBody.carriesIdfa(#"{"IDFA":"x"}"#))
        XCTAssertTrue(AttributionBody.carriesIdfa(#"{"a":{"i_d-fa":"x"}}"#))
        XCTAssertTrue(AttributionBody.carriesIdfa(#"{"a":[{"idfa":"x"}]}"#))
        XCTAssertFalse(AttributionBody.carriesIdfa(#"{"adservices_token":"t","device_id":"d"}"#))
        XCTAssertFalse(AttributionBody.carriesIdfa(#"{"note":"idfa"}"#), "değer değil anahtar aranır")
        XCTAssertFalse(AttributionBody.carriesIdfa(""))
        XCTAssertFalse(AttributionBody.carriesIdfa("{bozuk"))
    }

    // MARK: - Transport

    func testTransportIzlemeUcundaSondakiEgikCizgiCiftlenmez() async {
        await Registry.shared.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        cfg.httpAdditionalHeaders = ["X-Stub": Stub.status(200, headers: [:]).header]
        let t = Transport(endpoint: URL(string: "https://attr.example.com/")!, apiKey: "k",
                          session: URLSession(configuration: cfg))
        _ = await t.post(path: "/v1/attribution", body: "{}")
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.url?.absoluteString, "https://attr.example.com/v1/attribution")
    }

    // MARK: - Kaynak taraması

    /// İzleme host'u kaynakta yalnız `Configuration.swift`'te geçer; ingest host'u da yalnız
    /// orada. Başka bir dosyaya sabit adres yazılırsa izleme/ingest ayrımı sessizce bozulabilir.
    func testHostAdlariYalnizConfigurationdaGecer() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw XCTSkip("kaynak dizini okunamadı: \(sources.path)")
        }
        var hits: [String: [String]] = [:]
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for host in ["attr.cizeylem.com", "in.cizeylem.com"] where text.contains(host) {
                hits[host, default: []].append(url.lastPathComponent)
            }
        }
        guard scanned > 0 else { throw XCTSkip("kaynak dosyası okunamadı (simülatör sandbox'ı?)") }
        for (host, names) in hits {
            for name in names where name != "Configuration.swift" {
                XCTFail("\(host) Configuration.swift dışında geçiyor: \(name)")
            }
        }
        XCTAssertEqual(hits["attr.cizeylem.com"], ["Configuration.swift"])
        XCTAssertEqual(hits["in.cizeylem.com"], ["Configuration.swift"])
    }
}

import XCTest
@testable import CizeylemAttribution
@testable import Cizeylem

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Sink'e ulaşan alanları olduğu gibi kaydeder: YALNIZ çağıranın kapısını sınar (süzme yok).
final class RecordingSink: AttributionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var identified: [[String: String]] = []
    private var anonymous: [[String: String]] = []
    func sendIdentified(_ fields: [String: Any]) async {
        let f = fields.compactMapValues { $0 as? String }
        lock.withLock { identified.append(f) }
    }
    func sendAnonymous(_ fields: [String: Any]) async {
        let f = fields.compactMapValues { $0 as? String }
        lock.withLock { anonymous.append(f) }
    }
    func snapshot() -> (identified: [[String: String]], anonymous: [[String: String]]) {
        lock.lock(); defer { lock.unlock() }
        return (identified, anonymous)
    }
}

actor E2ESender: AttributionSending {
    private(set) var calls: [(path: String, body: String)] = []
    func post(path: String, body: String) async -> (Outcome, retryAfter: Double?) {
        calls.append((path, body)); return (.ok, nil)
    }
    func all() -> [(path: String, body: String)] { calls }
}

final class AttributionTests: XCTestCase {
    private let realIdfa = "11111111-2222-3333-4444-555555555555"

    private struct Probe {
        let tokenReads = Counter(), statusReads = Counter(), idfaReads = Counter()
        let signals: Attribution.Signals
        init(token: String? = "tok", status: String = "authorized", idfa: String? = nil) {
            let t = tokenReads, s = statusReads, i = idfaReads
            signals = Attribution.Signals(
                token: { t.hit(); return token },
                attStatus: { s.hit(); return status },
                idfa: { i.hit(); return idfa })
        }
    }

    private func combos() -> [Consent] {
        var out: [Consent] = []
        for a in [false, true] { for b in [false, true] { for c in [false, true] {
            out.append(Consent(analytics: a, attribution: b, adSharing: c))
        } } }
        return out
    }

    private func run(_ consent: Consent, _ probe: Probe) async -> (identified: [[String: String]], anonymous: [[String: String]]) {
        let sink = RecordingSink()
        await Attribution.run(sink: sink, consent: consent, signals: probe.signals)
        return sink.snapshot()
    }

    // MARK: - Karar 1: IDFA iki kapıdan geçer

    func testAdSharingKapaliykenIDFAOkunmaz() async {
        let p = Probe(idfa: realIdfa)
        let r = await run(Consent(analytics: true, attribution: true, adSharing: false), p)
        XCTAssertEqual(p.idfaReads.count, 0)
        XCTAssertNil(r.identified.first?["idfa"])
    }

    func testATTAuthorizedDegilkenIDFAOkunmaz() async {
        for status in ["denied", "restricted", "not_determined", "unavailable"] {
            let p = Probe(status: status, idfa: realIdfa)
            let r = await run(Consent(analytics: true, attribution: true, adSharing: true), p)
            XCTAssertEqual(p.idfaReads.count, 0, status)
            XCTAssertNil(r.identified.first?["idfa"], status)
        }
    }

    func testIkiKapiAcikkenIDFAKimlikliUcaGider() async {
        let p = Probe(idfa: realIdfa)
        let r = await run(Consent(analytics: true, attribution: true, adSharing: true), p)
        XCTAssertEqual(r.identified.count, 1)
        XCTAssertEqual((r.identified.first ?? [:])["idfa"], realIdfa)
        XCTAssertEqual((r.identified.first ?? [:])["att_status"], "authorized")
        XCTAssertEqual((r.identified.first ?? [:])["adservices_token"], "tok")
        XCTAssertTrue(r.anonymous.isEmpty)
    }

    func testSifirIDFAGonderilmez() async {
        for zero in ["00000000-0000-0000-0000-000000000000", "00000000000000000000000000000000", "", "  ", "\n", " \n\t "] {
            let r = await run(Consent(analytics: true, attribution: true, adSharing: true), Probe(idfa: zero))
            XCTAssertNil(r.identified.first?["idfa"], "'\(zero)'")
        }
    }

    // MARK: - Karar 2, ÇAĞIRANIN KAPISI (süzme bu testlerde yok)

    func testYalnizAdSharingAcikkenAnonUcaIdfaGitmezVeOkunmaz() async {
        let p = Probe(idfa: realIdfa)
        let r = await run(Consent(adSharing: true), p)
        XCTAssertEqual(r.anonymous.count, 1)
        XCTAssertNil((r.anonymous.first ?? [:])["idfa"])
        XCTAssertEqual(p.idfaReads.count, 0, "kapı IDFA'yı okumadan kesmeli")
        XCTAssertTrue(r.identified.isEmpty)
    }

    func testAnonRotadaHicbirKombinasyondaKimlikAlaniUretilmez() async {
        for consent in combos() where !consent.allowsIdentifiedAttribution {
            let p = Probe(idfa: realIdfa)
            let r = await run(consent, p)
            XCTAssertTrue(r.identified.isEmpty, "\(consent)")
            XCTAssertEqual(r.anonymous.count, 1, "\(consent)")
            for key in ["idfa", "device_id", "user_id", "distinct_id", "att_status"] {
                XCTAssertNil((r.anonymous.first ?? [:])[key], "\(consent) \(key)")
            }
            XCTAssertEqual((r.anonymous.first ?? [:])["adservices_token"], "tok")
            XCTAssertEqual(p.idfaReads.count, 0, "\(consent)")
            XCTAssertEqual(p.statusReads.count, 0, "\(consent)")
        }
    }

    // MARK: - Karar 5 ve 8: rota, sekiz kombinasyon

    func testAttributionRizasiVarsaAlanlarKimlikliUcaGider() async {
        let r = await run(Consent(analytics: true, attribution: true), Probe())
        XCTAssertEqual(r.identified.count, 1)
        XCTAssertTrue(r.anonymous.isEmpty)
        XCTAssertEqual((r.identified.first ?? [:])["adservices_token"], "tok")
        XCTAssertNil((r.identified.first ?? [:])["att_status"])
    }

    func testAttributionTekBasinaYetmezAnonUcaGider() async {
        let r = await run(Consent(attribution: true, adSharing: true), Probe(idfa: realIdfa))
        XCTAssertTrue(r.identified.isEmpty)
        XCTAssertEqual(r.anonymous.count, 1)
    }

    func testRizaYoksaAnonUcaGiderVeGovdedeKimlikBulunmaz() async {
        let p = Probe(idfa: realIdfa)
        let r = await run(Consent(), p)
        XCTAssertEqual(r.anonymous, [["adservices_token": "tok"]])
        XCTAssertTrue(r.identified.isEmpty)
        XCTAssertEqual(p.statusReads.count, 0)
        XCTAssertEqual(p.idfaReads.count, 0)
    }

    func testSekizKombinasyondaIdfaVeAttStatusOkunmaVeGonderilmeTablosu() async {
        for consent in combos() {
            let p = Probe(idfa: realIdfa)
            let r = await run(consent, p)
            let sent = (r.identified + r.anonymous)
            XCTAssertEqual(sent.count, 1, "\(consent)")
            // Sabit beklenti: yalnız üçü açıkken açılır. `Consent` mantığının kopyası DEĞİL.
            let wantStatus = [Consent(analytics: true, attribution: true, adSharing: true)].contains(consent)
            let wantIdfa = wantStatus
            XCTAssertEqual((sent.first ?? [:])["att_status"] != nil, wantStatus, "att_status \(consent)")
            XCTAssertEqual((sent.first ?? [:])["idfa"] != nil, wantIdfa, "idfa \(consent)")
            XCTAssertEqual(p.idfaReads.count, wantIdfa ? 1 : 0, "idfa okuma \(consent)")
            XCTAssertEqual(p.statusReads.count, wantStatus ? 1 : 0, "durum okuma \(consent)")
            XCTAssertEqual(p.tokenReads.count, 1, "token okuma \(consent)")
        }
    }

    func testTokenYoksaVeGonderilecekBaskaAlanYoksaHicbirSeyGonderilmez() async {
        let r = await run(Consent(), Probe(token: nil))
        XCTAssertTrue(r.identified.isEmpty)
        XCTAssertTrue(r.anonymous.isEmpty)
    }

    func testTokenYokkenAttStatusYineGider() async {
        let r = await run(Consent(analytics: true, attribution: true, adSharing: true), Probe(token: nil, status: "denied"))
        XCTAssertEqual(r.identified, [["att_status": "denied"]])
    }

    // MARK: - Uçtan uca (iki katman birlikte)

    func testUcTanUcaYalnizAdSharingAcikkenAnonGovdedeIdfaYok() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cz-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "co.cizeylem.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let sender = E2ESender()
        var d = Core.Dependencies()
        d.platform = Platform(name: "ios", queueDirectory: root.appendingPathComponent("q"),
                              maxEvents: 10, maxBytes: 100_000, flushAt: 30)
        d.defaultsSuite = suite
        d.lifecycle = LifecycleLocation(url: root.appendingPathComponent("life"), usesDefaults: false)
        d.amplitudeLibraryDirectory = root.appendingPathComponent("amp")
        d.makeAttributionSender = { _, _ in sender }
        let core = Core(config: Configuration(writeKey: "ck_w_t", flushInterval: 0, legacyAmplitude: false), deps: d)
        await core.start()
        let consent = Consent(adSharing: true)
        await core.setConsent(consent)
        let sink = CoreAttributionSink { route, fields in await core.sendAttribution(route, fields) }
        await Attribution.run(sink: sink, consent: consent, signals: Probe(idfa: realIdfa).signals)
        let calls = await sender.all()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.path, "/v1/attribution/anon")
        XCTAssertFalse((calls.first?.body ?? "").contains("idfa"))
        XCTAssertFalse((calls.first?.body ?? "").contains(realIdfa))
        XCTAssertFalse((calls.first?.body ?? "").contains("device_id"))
    }
}

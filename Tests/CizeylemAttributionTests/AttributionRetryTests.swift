import XCTest
@testable import CizeylemAttribution
@testable import Cizeylem

/// Kalıcı durum + sonuç bildiren sahte sink (çekirdeğin yerine).
actor FakeStateSink: AttributionStateSink {
    enum Mode { case persistent, unavailable, unreadable }
    struct Delivery { let route: AttributionRoute; let fields: [String: String]; let envelope: AttributionEnvelope }

    var mode: Mode
    var stored: AttributionState?
    var results: [AttributionDelivery]
    private(set) var deliveries: [Delivery] = []

    init(mode: Mode = .persistent, stored: AttributionState? = nil, results: [AttributionDelivery] = []) {
        self.mode = mode
        self.stored = stored
        self.results = results
    }

    func setResults(_ r: [AttributionDelivery]) { results = r }
    func setMode(_ m: Mode) { mode = m }

    func loadAttributionState() async -> AttributionStateLoad {
        switch mode {
        case .unavailable: return .unavailable
        case .unreadable: return .unreadable
        case .persistent: return stored.map(AttributionStateLoad.present) ?? .absent
        }
    }

    @discardableResult
    func saveAttributionState(_ state: AttributionState) async -> Bool {
        guard mode == .persistent else { return false }
        stored = state
        return true
    }

    // `Any` actor sınırını geçemez: alanlar çağıranın tarafında düz metne çevrilir.
    nonisolated func deliver(_ route: AttributionRoute, _ fields: [String: Any], envelope: AttributionEnvelope) async
        -> AttributionDelivery {
        let flat = fields.compactMapValues { $0 as? String }
        return await record(route, flat, envelope)
    }

    private func record(_ route: AttributionRoute, _ fields: [String: String], _ envelope: AttributionEnvelope)
        -> AttributionDelivery {
        deliveries.append(Delivery(route: route, fields: fields, envelope: envelope))
        return results.isEmpty ? .sent : results.removeFirst()
    }

    nonisolated func sendIdentified(_ fields: [String: Any]) async {}
    nonisolated func sendAnonymous(_ fields: [String: Any]) async {}
}

/// Sahte saat, uuid sırası, bekleme kaydı, sıralı token.
final class RetryHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64 = 1_763_000_000_000
    private var _uuid = 0
    private var _sleeps: [TimeInterval] = []
    private var _tokens: [TokenRead] = []
    private var _status = "denied"
    private var _foreground: (@Sendable () -> Void)?
    /// Kurulum anı: varsayılan bir dakika önce (taze kurulum).
    private var _installedAt: Int64? = 1_763_000_000_000 - 60_000
    let tokenReads = Counter()

    var now: Int64 { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
    var status: String { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
    var installedAt: Int64? { get { lock.withLock { _installedAt } } set { lock.withLock { _installedAt = newValue } } }
    func tokens(_ t: [TokenRead]) { lock.withLock { _tokens = t } }
    func fireForeground() { lock.withLock { _foreground }?() }

    func runner() -> AttributionRunner {
        let signals = Attribution.Signals(
            token: { [self] in
                tokenReads.hit()
                return lock.withLock { _tokens.isEmpty ? .token("tok-\(tokenReads.count)") : _tokens.removeFirst() }
            },
            attStatus: { [self] in status },
            idfa: { "11111111-2222-3333-4444-555555555555" })
        var env = AttributionRunner.Environment(signals: signals)
        env.nowMs = { [self] in now }
        env.uuid = { [self] in lock.withLock { _uuid += 1; return "uuid-\(_uuid)" } }
        env.sleep = { [self] d in lock.withLock { _sleeps.append(d) } }
        env.installedAtMs = { [self] in installedAt }
        env.observeForeground = { [self] handler in
            lock.withLock { _foreground = handler }
            return NSObject()
        }
        return AttributionRunner(environment: env)
    }
}

final class AttributionRetryTests: XCTestCase {
    private let identified = Consent(analytics: true, attribution: true)
    private let full = Consent(analytics: true, attribution: true, adSharing: true)

    /// Zamanlanmış tekrarlar bitene kadar bekler.
    private func settle(_ r: AttributionRunner) async {
        var last: Task<Void, Never>?
        while let t = await r.retryTask, t != last {
            await t.value
            last = t
        }
    }

    func testAgYokkenBekliyorSonraAyniZarflaGider() async {
        let h = RetryHarness()
        let sink = FakeStateSink(results: [.retryLater, .retryLater, .sent])
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        await settle(r)
        let d = await sink.deliveries
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(Set(d.map(\.envelope.insertId)), ["uuid-1"], "insert_id tekrarlarda değişmemeli")
        XCTAssertEqual(Set(d.map { $0.envelope.timeMs ?? 0 }), [1_763_000_000_000])
        XCTAssertEqual(d.map { $0.fields["adservices_token"] ?? "" }, ["tok-1", "tok-2", "tok-3"],
                       "her denemede taze token")
        XCTAssertEqual(h.sleeps, [5, 30])
        let st = await sink.stored
        XCTAssertEqual(st?.pending, false)
        XCTAssertEqual(st?.attempts, 3)
        XCTAssertEqual(st?.sentRoute, "identified")
    }

    func testYeniSurecteBekleyenSinyalGiderGonderilmisGitmez() async {
        let h = RetryHarness()
        let sink = FakeStateSink(results: [.retryLater, .retryLater, .retryLater, .retryLater, .retryLater])
        let r1 = h.runner()
        await r1.start(sink: sink, consent: identified)
        await settle(r1)
        let first = await sink.stored
        XCTAssertEqual(first?.pending, true)

        await sink.setResults([.sent])
        let r2 = h.runner()   // yeni süreç
        await r2.start(sink: sink, consent: identified)
        let d = await sink.deliveries
        XCTAssertEqual(d.count, 6)
        XCTAssertEqual(d.last?.envelope.insertId, first?.insertId)

        let r3 = h.runner()
        await r3.start(sink: sink, consent: identified)
        let after = await sink.deliveries
        XCTAssertEqual(after.count, 6, "gönderilmiş sinyal yeniden gitmemeli")
    }

    func testGeriCekilmeBitinceOnPlanaGelisBeklenir() async {
        let h = RetryHarness()
        let sink = FakeStateSink(results: Array(repeating: .retryLater, count: 10))
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        await settle(r)
        XCTAssertEqual(h.sleeps, [5, 30, 120, 600])
        let n = await sink.deliveries.count
        XCTAssertEqual(n, 5)
        h.fireForeground()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await settle(r)
        XCTAssertEqual(h.sleeps, [5, 30, 120, 600, 5, 30, 120, 600], "ön plan geri çekilmeyi baştan başlatır")
    }

    func testGeciciTokenHatasindaGonderilmezSonraGider() async {
        let h = RetryHarness()
        h.tokens([.transient, .transient, .token("iyi")])
        let sink = FakeStateSink()
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        await settle(r)
        let d = await sink.deliveries
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.fields["adservices_token"], "iyi")
        XCTAssertEqual(h.sleeps, [5, 30])
        let st = await sink.stored
        XCTAssertEqual(st?.attempts, 3)
    }

    func testTokenYokVeBaskaAlanYoksaBeklemeKapanir() async {
        let h = RetryHarness()
        h.tokens([.unavailable])
        let sink = FakeStateSink()
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        let d = await sink.deliveries
        XCTAssertTrue(d.isEmpty)
        let st = await sink.stored
        XCTAssertEqual(st?.pending, false)
    }

    func testReddedilenTekrarDenenmezDurdurulanYeniStartaKadarBekler() async {
        let h = RetryHarness()
        let rejected = FakeStateSink(results: [.rejected])
        let r1 = h.runner()
        await r1.start(sink: rejected, consent: identified)
        await settle(r1)
        let rejectedCount = await rejected.deliveries.count
        XCTAssertEqual(rejectedCount, 1)
        let rejectedState = await rejected.stored
        XCTAssertEqual(rejectedState?.pending, false)

        let stopped = FakeStateSink(results: [.stopped, .sent])
        let r2 = h.runner()
        await r2.start(sink: stopped, consent: identified)
        await settle(r2)
        h.fireForeground()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let stoppedCount = await stopped.deliveries.count
        XCTAssertEqual(stoppedCount, 1, "401/403 sonrası bu süreçte denenmez")
        await r2.start(sink: stopped, consent: identified)
        let afterStart = await stopped.deliveries.count
        XCTAssertEqual(afterStart, 2, "yeni start yeniden dener")
    }

    func testAttDegisinceYeniSinyalGider() async {
        let h = RetryHarness()
        h.status = "not_determined"
        let sink = FakeStateSink()
        let r = h.runner()
        await r.start(sink: sink, consent: full)
        h.status = "authorized"
        await r.foreground()
        await r.foreground()   // durum aynı: üçüncü sinyal yok
        let d = await sink.deliveries
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].fields["att_status"], "not_determined")
        XCTAssertNil(d[0].fields["idfa"])
        XCTAssertEqual(d[1].fields["att_status"], "authorized")
        XCTAssertNotNil(d[1].fields["idfa"])
        XCTAssertNotEqual(d[0].envelope.insertId, d[1].envelope.insertId)
    }

    func testRizaKimlikliYoluAcincaYeniSinyalGider() async {
        let h = RetryHarness()
        let sink = FakeStateSink()
        let r = h.runner()
        await r.start(sink: sink, consent: Consent(analytics: true))   // kimliksiz rota, durum kalıcı
        await r.start(sink: sink, consent: identified)
        let d = await sink.deliveries
        XCTAssertEqual(d.map(\.route), [.anonymous, .identified])
    }

    func testAltiGundenEskiBekleyenSinyalYeniZarflaGider() async {
        let h = RetryHarness()
        let old = AttributionState(pending: true, insertId: "eski", firstSignalAtMs: h.now - 7 * 86_400_000)
        let sink = FakeStateSink(stored: old)
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        let d = await sink.deliveries
        XCTAssertEqual(d.first?.envelope.insertId, "uuid-1")
        XCTAssertEqual(d.first?.envelope.timeMs, h.now)
    }

    func testBesGunlukBekleyenSinyalKurulumAniniKorur() async {
        let h = RetryHarness()
        let t0 = h.now - 5 * 86_400_000
        let sink = FakeStateSink(stored: AttributionState(pending: true, insertId: "ilk", firstSignalAtMs: t0))
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        let d = await sink.deliveries
        XCTAssertEqual(d.first?.envelope.insertId, "ilk")
        XCTAssertEqual(d.first?.envelope.timeMs, t0)
    }

    func testEskiKurulumKayitsizGondermezDurumuKaydeder() async {
        let h = RetryHarness()
        h.status = "authorized"
        h.installedAt = h.now - 40 * 86_400_000   // 0.3.0'dan yükseltme ya da SDK'yı yeni alan uygulama
        let sink = FakeStateSink()
        let r = h.runner()
        await r.start(sink: sink, consent: full)
        let d = await sink.deliveries
        XCTAssertTrue(d.isEmpty, "eski kurulumda kayıt yokluğu yeni sinyal açmamalı")
        let st = await sink.stored
        XCTAssertEqual(st?.pending, false)
        XCTAssertEqual(st?.sentAttStatus, "authorized")
        // Sonra ATT değişirse yeni sinyal gider.
        h.status = "denied"
        await r.foreground()
        let after = await sink.deliveries.count
        XCTAssertEqual(after, 1)
    }

    func testKurulumAniBilinmiyorsaSinyalGider() async {
        let h = RetryHarness()
        h.installedAt = nil
        let sink = FakeStateSink()
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        let n = await sink.deliveries.count
        XCTAssertEqual(n, 1)
    }

    /// Gözden geçirme bulgusu 2: ilk süreçte rıza sonradan verildi ve sinyal gidemedi; ikinci
    /// süreç kayıt bulamasa da taze kurulum olduğu için sinyali gönderir.
    func testRizaSonradanVerilipSinyalGidemezseIkinciSurecteGider() async {
        let h = RetryHarness()
        let sink = FakeStateSink(mode: .unavailable, results: Array(repeating: .retryLater, count: 5))
        let r1 = h.runner()
        await r1.start(sink: sink, consent: Consent())
        await settle(r1)
        await sink.setMode(.persistent)   // rıza verildi; süreç bir şey yazamadan öldü
        await sink.setResults([.sent])
        h.now += 3_600_000
        let r2 = h.runner()
        await r2.start(sink: sink, consent: identified)
        let d = await sink.deliveries
        XCTAssertEqual(d.last?.route, .identified)
        let st = await sink.stored
        XCTAssertEqual(st?.pending, false)
    }

    /// Gözden geçirme bulgusu 3: rızasız giden kimliksiz sinyalden sonra aynı süreçte analytics
    /// verilince ikinci kimliksiz sinyal gitmez; bellek diske taşınır.
    func testAyniSurecteAnalyticsGelinceIkinciAnonGitmez() async {
        let h = RetryHarness()
        let sink = FakeStateSink(mode: .unavailable)
        let r = h.runner()
        await r.start(sink: sink, consent: Consent())
        await sink.setMode(.persistent)
        await r.start(sink: sink, consent: Consent(analytics: true))
        let d = await sink.deliveries
        XCTAssertEqual(d.map(\.route), [.anonymous])
        let st = await sink.stored
        XCTAssertEqual(st?.insertId, d.first?.envelope.insertId)
        XCTAssertEqual(st?.pending, false)
    }

    /// Gözden geçirme bulgusu 1: rıza yokken sinyal yalnız kurulumdan sonraki ilk dakikalarda açılır.
    func testRizasizEskiKurulumdaHerAcilistaGitmez() async {
        let h = RetryHarness()
        h.installedAt = h.now - 2 * 3_600_000
        let sink = FakeStateSink(mode: .unavailable)
        for _ in 0..<3 {
            let r = h.runner()   // her biri yeni süreç
            await r.start(sink: sink, consent: Consent())
        }
        let n = await sink.deliveries.count
        XCTAssertEqual(n, 0)
    }

    func testDenemeSurerkenGelenStartKaybolmaz() async {
        let h = RetryHarness()
        let gate = Gate()
        let sink = SlowSink(gate: gate)
        let r = h.runner()
        let first = Task { await r.start(sink: sink, consent: Consent(analytics: true)) }   // kimliksiz, takılı
        await gate.waitEntered()
        await r.start(sink: sink, consent: identified)   // deneme sürerken yeni rıza
        await gate.release()
        await first.value
        let routes = await sink.routes
        XCTAssertEqual(routes, [.anonymous, .identified], "süren deneme bitince yeni rızayla yeniden koşmalı")
    }

    func testEskiSiraNumarasiYokSayilir() async {
        let h = RetryHarness()
        let sink = FakeStateSink(results: [.retryLater, .retryLater, .retryLater, .retryLater, .retryLater])
        let r = h.runner()
        await r.start(sink: sink, consent: identified, sequence: 2)
        await settle(r)
        await r.start(sink: sink, consent: Consent(), sequence: 1)   // geç koşan eski çağrı
        await r.foreground()
        let d = await sink.deliveries
        XCTAssertEqual(Set(d.map(\.route)), [.identified])
    }

    func testKaliciTokenHatasindaSinirdanSonraTokensizGider() async {
        let h = RetryHarness()
        h.tokens(Array(repeating: .transient, count: 20))
        let sink = FakeStateSink(stored: AttributionState(pending: true, insertId: "i", firstSignalAtMs: h.now, attempts: 5))
        let r = h.runner()
        await r.start(sink: sink, consent: full)
        let d = await sink.deliveries
        XCTAssertEqual(d.count, 1)
        XCTAssertNil(d.first?.fields["adservices_token"])
        XCTAssertNotNil(d.first?.fields["att_status"])
    }

    func testOkunamayanDurumdaDenenmez() async {
        let h = RetryHarness()
        let sink = FakeStateSink(mode: .unreadable)
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        let n = await sink.deliveries.count
        XCTAssertEqual(n, 0)
        XCTAssertEqual(h.tokenReads.count, 0, "kilitli cihazda token bile üretilmez")
    }

    func testRizasizDurumYalnizSurecBelleginde() async {
        let h = RetryHarness()
        let sink = FakeStateSink(mode: .unavailable, results: [.retryLater, .sent])
        let r = h.runner()
        await r.start(sink: sink, consent: Consent())
        await settle(r)
        await r.foreground()
        let d = await sink.deliveries
        XCTAssertEqual(d.count, 2, "aynı süreçte tekrar dener, gittikten sonra durur")
        XCTAssertEqual(d.map(\.route), [.anonymous, .anonymous])
        XCTAssertEqual(Set(d.map(\.envelope.insertId)).count, 1)
        let st = await sink.stored
        XCTAssertNil(st, "rızasız kalıcı iz yok")
    }

    func testEsZamanliCagrilarTekIstek() async {
        let h = RetryHarness()
        let sink = FakeStateSink()
        let r = h.runner()
        let consent = Consent(analytics: true, attribution: true)
        async let a: Void = r.start(sink: sink, consent: consent)
        async let b: Void = r.foreground()
        async let c: Void = r.start(sink: sink, consent: consent)
        _ = await (a, b, c)
        let n = await sink.deliveries.count
        XCTAssertEqual(n, 1)
    }

    func testDurumBildirmeyenSinkTekSeferlik() async {
        let h = RetryHarness()
        let sink = RecordingSink()
        let r = h.runner()
        await r.start(sink: sink, consent: identified)
        await r.start(sink: sink, consent: identified)
        XCTAssertEqual(sink.snapshot().identified.count, 1)
    }

    func testIhtiyacKurallari() {
        let sent = AttributionState(pending: false, insertId: "i", firstSignalAtMs: 0, sentAttStatus: nil, sentRoute: "identified")
        XCTAssertTrue(AttributionRunner.needsNewSignal(sent, route: .identified, status: "authorized"),
                      "durumsuz gitmiş, durum okunabilir oldu")
        let migrated = AttributionState(pending: false, insertId: "i", firstSignalAtMs: 0)
        XCTAssertFalse(AttributionRunner.needsNewSignal(migrated, route: .identified, status: "authorized"),
                       "devralınan kayıt")
        XCTAssertFalse(AttributionRunner.needsNewSignal(migrated, route: .identified, status: nil))
    }
}

/// Tek kapılı bekleme: ilk teslim girer ve serbest bırakılana kadar bekler.
actor Gate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

/// İlk teslimde kapıda bekleyen sink.
actor SlowSink: AttributionStateSink {
    let gate: Gate
    private(set) var routes: [AttributionRoute] = []
    private var stored: AttributionState?
    init(gate: Gate) { self.gate = gate }

    func loadAttributionState() async -> AttributionStateLoad { stored.map(AttributionStateLoad.present) ?? .absent }
    @discardableResult func saveAttributionState(_ state: AttributionState) async -> Bool { stored = state; return true }
    nonisolated func deliver(_ route: AttributionRoute, _ fields: [String: Any], envelope: AttributionEnvelope) async
        -> AttributionDelivery {
        await record(route)
    }
    private func record(_ route: AttributionRoute) async -> AttributionDelivery {
        routes.append(route)
        if routes.count == 1 { await gate.enter() }
        return .sent
    }
    nonisolated func sendIdentified(_ fields: [String: Any]) async {}
    nonisolated func sendAnonymous(_ fields: [String: Any]) async {}
}

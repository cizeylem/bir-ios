import Foundation
import Cizeylem
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Attribution sinyallerini toplayıp çekirdeğe (sink) bırakır.
///
/// Kapılar `Consent`'te tek yerdedir; burada birleştirilmez, çağrılır. Çekirdekteki
/// `AttributionBody` süzmesi bunlardan bağımsız ikinci katmandır.
///
/// **0.4.0 (SPEC §8.2):** `start` her açılışta çağrılır. Sinyal sunucu `2xx` dönene kadar
/// "bekliyor" kalır, uygulama her ön plana geldiğinde ve aynı süreçte geri çekilmeyle yeniden
/// denenir; her denemede taze token üretilir. Bir kez başarıyla gitmiş sinyal, ATT durumu ya da
/// rota değişmedikçe tekrar gönderilmez. Uygulamada "bir kez gönder" koruması yazılmaz.
public enum Attribution {
    /// Okuma kaynakları. Üretimde gerçek sistem çağrıları; testte sayaçlı sahteleri.
    struct Signals: Sendable {
        var token: @Sendable () -> TokenRead
        var attStatus: @Sendable () -> String
        var idfa: @Sendable () -> String?

        static let live = Signals(
            token: { AdServicesToken.read() },
            attStatus: { TrackingStatus.current() },
            idfa: { TrackingStatus.idfa() })
    }

    /// Sinyali gönderir ya da bekleyen sinyali yeniden dener; çağıranı bloklamaz.
    ///
    /// **Her açılışta çağırın.** Kalıcı durum ve tekrar SDK'dadır: gönderilmiş sinyal yeniden
    /// gitmez, gitmemiş olan gidene kadar denenir. `consent` o anki rızanın kopyasıdır; değişince
    /// yeniden çağrılmalıdır (ön plan tetikleyicisi son verilen kopyayı kullanır).
    ///
    /// Durum yalnız rıza kalıcı iz bırakmaya izin veriyorsa (`analytics`) diske yazılır. Rızasızken
    /// tekrar yalnız bu süreç boyunca sürer ve sinyal yalnız kurulumdan sonraki ilk 15 dakikada açılır.
    /// Kayıt yokken 30 günden eski kurulum (0.3.0'dan yükseltme) sinyali gitmiş sayar (SPEC §8.2).
    ///
    /// Dönüşüm değeri yazıcısını **kurmaz**: o ayrı ve açık bir çağrıdır
    /// (`enableConversionWriter`). Burada bir varsayılan yoktur, çünkü unutulan çağrı kapalı kalmalı.
    public static func start(sink: AttributionSink, consent: Consent) {
        // Sıra numarası çağrı anında alınır: art arda iki çağrının görevleri ters sırayla koşsa da
        // koşucu eski rızaya dönmez.
        let seq = startSequence.next()
        Task.detached(priority: .utility) {
            await AttributionRunner.shared.start(sink: sink, consent: consent, sequence: seq)
        }
    }

    private static let startSequence = Sequence()

    /// Kilitli artan sayaç (çağıranın thread'inde, beklemeden).
    final class Sequence: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 { lock.withLock { value += 1; return value } }
    }

    #if DEBUG
    /// YALNIZ DEBUG derleme: kalıcı durumdan bağımsız, taze token ve yeni `insert_id` ile bir sinyal
    /// gönderir. Kurulumdan günler sonra üretilen token'ın aynı kurulumu çözüp çözmediğini canlıda
    /// denemek içindir (cizeylem-1 BACKLOG ASA.2). Durumu değiştirmez.
    public static func debugSendFreshToken(sink: AttributionSink, consent: Consent) {
        Task.detached(priority: .utility) {
            await AttributionRunner.shared.debugSendFresh(sink: sink, consent: consent)
        }
    }
    #endif

    /// SKAN/AAK dönüşüm değeri yazıcısını açar. **Varsayılan kapalıdır** (K8): host uygulama paralel
    /// testte değeri AppsFlyer yazdırır ve iki yazıcı postback'i geri alınamaz biçimde bozar.
    /// Yalnız host bu işi üstlenecekse çağırmalıdır.
    ///
    /// - `schemaURL`: uzaktaki sürümlü JSON şema (https). Alınamaz ya da geçersizse hiçbir şey
    ///   yazılmaz; yedek şema yoktur.
    /// - `events`: şemadaki kurallara göre değerlendirilen event sayaçları.
    /// - tvOS'ta çağrı sessizce hiçbir şey yapmaz (SKAdNetwork/AAK yok).
    public static func enableConversionWriter(
        schemaURL: URL, events: [String: Int] = ["first_open": 1]
    ) {
        _ = enableConversionWriterTask(schemaURL: schemaURL, events: events, environment: .live)
    }

    /// Test girişi: paylaşılan koşucu yerine verilen sinyallerle kurulan **ayrı** bir koşucuda
    /// `start`'ı yürütür ve bekleyebilmek için `Task` döndürür.
    @discardableResult
    static func startTask(sink: AttributionSink, consent: Consent, signals: Signals,
                          conversion: ConversionWriter.Environment) -> Task<Void, Never> {
        // `conversion` bilerek kullanılmaz: start'ın yazıcıya dokunmadığı testle sabitlenir.
        _ = conversion
        let runner = AttributionRunner(environment: .init(signals: signals))
        return Task.detached(priority: .utility) {
            await runner.start(sink: sink, consent: consent)
        }
    }

    @discardableResult
    static func enableConversionWriterTask(
        schemaURL: URL, events: [String: Int],
        environment: ConversionWriter.Environment
    ) -> Task<ConversionWriter.Outcome, Never> {
        Task.detached(priority: .utility) {
            await ConversionWriter.run(schemaURL: schemaURL, events: events, environment: environment)
        }
    }

    /// Toplanan sinyal: rota, gövde alanları ve gövdeye giren ATT durumu.
    struct Collected {
        var route: AttributionRoute
        var fields: [String: Any]
        /// Gövdeye giren ATT durumu (rıza izin vermediyse `nil`).
        var status: String?
        /// Token üretimi geçici hatayla düştü: bu deneme gönderilmez.
        var tokenTransient: Bool
    }

    /// Kapılara göre sinyalleri okur. Rıza yoksa bile token okunur: kimliksiz uç SPEC §5'te buna
    /// açıkça izin verir.
    static func collect(consent: Consent, signals: Signals) -> Collected {
        var fields: [String: Any] = [:]
        var transient = false
        switch signals.token() {
        case .token(let token): fields["adservices_token"] = token
        case .transient: transient = true
        case .unavailable: break
        }

        let route: AttributionRoute = consent.allowsIdentifiedAttribution ? .identified : .anonymous

        // Her kapı kendi başına karar verir; biri ötekine yaslanmaz (biri bozulursa diğeri tutar).
        let wantsStatus = consent.allowsAttStatus
        let wantsIdfa = consent.allowsIdfa(on: route)

        // Durum rızasızken okunmaz bile; IDFA ayrıca ATT `authorized` ister (iki kapı).
        var status: String?
        if wantsStatus || wantsIdfa { status = signals.attStatus() }
        var sentStatus: String?
        if wantsStatus, let status { fields["att_status"] = status; sentStatus = status }
        if wantsIdfa, status == "authorized", let idfa = usable(signals.idfa()) {
            fields["idfa"] = idfa
        }
        return Collected(route: route, fields: fields, status: sentStatus, tokenTransient: transient)
    }

    /// Tek seferlik gönderim (0.3.0 davranışı): kalıcı durum bildirmeyen bir sink'le kullanılır
    /// (host `AttributionSink`'i kendisi uyguluyorsa). Geçici token hatasında token'sız gider.
    static func run(sink: AttributionSink, consent: Consent, signals: Signals) async {
        let c = collect(consent: consent, signals: signals)
        guard !c.fields.isEmpty else { return }
        switch c.route {
        case .identified: await sink.sendIdentified(c.fields)
        case .anonymous: await sink.sendAnonymous(c.fields)
        }
    }

    /// Sıfır reklam kimliği "izin yok"un sesidir (ATT kapalıyken sistem verir); kimlik değildir.
    private static func usable(_ idfa: String?) -> String? {
        guard let idfa else { return nil }
        let t = idfa.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = t.replacingOccurrences(of: "-", with: "")
        guard !digits.isEmpty, digits.contains(where: { $0 != "0" }) else { return nil }
        return t
    }
}

/// Bekleyen sinyalin tek yürütücüsü (SPEC §8.2). Aynı anda tek deneme: `start`, ön plan bildirimi ve
/// geri çekilme zamanlayıcısı aynı actor'den geçer.
actor AttributionRunner {
    struct Environment: Sendable {
        var signals: Attribution.Signals
        /// Duvar saati, epoch ms.
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        var uuid: @Sendable () -> String = { UUID().uuidString }
        var sleep: @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        /// Aynı süreçte geçici hatadan sonraki bekleme basamakları; bitince ön plana gelişe kalır.
        var backoff: [TimeInterval] = [5, 30, 120, 600]
        /// Ön plan bildirimini dinler; dönen nesne tutuldukça dinleme sürer. Testte `nil`.
        var observeForeground: (@Sendable (@escaping @Sendable () -> Void) -> AnyObject?)? = nil
        /// Uygulamanın kurulum anı (epoch ms; bilinmiyorsa `nil`). Cihaza iz yazmadan okunur:
        /// uygulama kabının `Library` dizininin oluşturulma tarihi (güncellemede değişmez).
        var installedAtMs: @Sendable () -> Int64? = { AttributionRunner.liveInstalledAtMs() }
    }

    static let shared = AttributionRunner(environment: Environment(
        signals: .live, observeForeground: AttributionRunner.liveForegroundObserver))

    /// Bu yaştan eski bekleyen sinyal `time` taşımaz: sunucu 7 günden eski olay zamanını düşürür
    /// (cizeylem-1 `PROTOCOL.md` §2). Yeni `insert_id` ve şimdiki zamanla gider.
    static let maxSignalAgeMs: Int64 = 6 * 24 * 60 * 60 * 1000

    /// Kalıcı kayıt yokken bu yaştan genç kurulum yeni sinyal açar; daha eskisi gitmiş sayılır.
    /// Kaydın yokluğu iki şey olabilir: yeni kurulum ya da SDK'nın bu sürümüyle ilk kez açılan eski
    /// kurulum (0.3.0'dan yükseltme, SDK'yı yeni alan uygulama). 30 gün Apple'ın tıklama penceresidir;
    /// bu pencerede ikinci sinyal gitse de sunucu aynı cihazın 30 gün içindeki ikinci token'ını
    /// Apple'a sormaz (cizeylem-1 PLAN-APPLE-ADS K3).
    static let freshInstallWindowMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// Rıza yokken (durum yazılamaz) sinyal yalnız kurulumdan sonraki bu süre içinde açılır: aksi hâlde
    /// her açılış yeni bir kimliksiz "kurulum" gönderirdi. Geri çekilme basamaklarının toplamını (~13 dk)
    /// kapsar.
    static let anonymousWindowMs: Int64 = 15 * 60 * 1000

    /// Bu kadar geçici token hatasından sonra sinyal token'sız gider (ATT durumu/IDFA kaybolmasın).
    static let transientTokenLimit = 6

    private let env: Environment
    private var sink: AttributionSink?
    private var consent = Consent()
    /// Durum diske yazılamıyorsa (rıza yok) süreç belleği.
    private var memory: AttributionState?
    private var running = false
    /// `401/403` ya da SDK kurulmadı: yeni bir `start` çağrısına kadar denenmez.
    private var stopped = false
    private var backoffStep = 0
    /// Zamanlanmış bir tekrar var mı. `retryTask` yalnız son zamanlanan görevdir (testler bekler);
    /// bittikten sonra da durur, karar bu bayraktan verilir.
    private var retryPending = false
    private(set) var retryTask: Task<Void, Never>?
    private var observer: AnyObject?
    /// Tek seferlik (0.3.0) yolda bu süreçte gönderildi mi.
    private var legacySent = false
    /// Deneme sürerken gelen istek (yeni `start`, ön plan): deneme bitince bir kez daha koşulur.
    private var rerun = false
    /// Son uygulanan `start`'ın sıra numarası ve her `start`'ta artan nesil (süren denemenin
    /// `stopped` sonucu yeni bir `start`'ı geçersiz kılmasın).
    private var lastSequence: UInt64 = 0
    private var generation = 0

    init(environment: Environment) {
        self.env = environment
    }

    func start(sink: AttributionSink, consent: Consent, sequence: UInt64? = nil) async {
        if let sequence {
            guard sequence > lastSequence else { return }
            lastSequence = sequence
        }
        self.sink = sink
        self.consent = consent
        stopped = false
        generation += 1
        if observer == nil, let observe = env.observeForeground {
            observer = observe { [weak self] in
                Task { await self?.foreground() }
            }
        }
        await attempt()
    }

    /// Uygulama ön plana geldi: geri çekilme baştan başlar.
    func foreground() async {
        backoffStep = 0
        await attempt()
    }

    func attempt() async {
        guard sink != nil, !stopped else { return }
        if running {
            rerun = true
            return
        }
        running = true
        repeat {
            rerun = false
            await attemptOnce()
        } while rerun && !stopped
        running = false
    }

    private func attemptOnce() async {
        guard let sink, !stopped else { return }
        let gen = generation

        guard let stateful = sink as? AttributionStateSink else {
            guard !legacySent else { return }
            legacySent = true
            await Attribution.run(sink: sink, consent: consent, signals: env.signals)
            return
        }

        var persistent = true
        var state: AttributionState
        switch await stateful.loadAttributionState() {
        case .unreadable:
            return
        case .present(let s):
            state = s
        case .absent:
            if let memory {
                // Bu süreçte rızasız (bellekte) başlamış sinyal: rıza gelince aynen diske taşınır,
                // ikinci bir sinyal açılmaz.
                state = memory
            } else if installedWithin(Self.freshInstallWindowMs) {
                state = fresh()
            } else {
                // Eski kurulum (0.3.0'dan yükseltme ya da SDK'yı yeni alan uygulama): sinyal gitmiş
                // sayılır. Aksi hâlde her eski kullanıcı bugün tarihli bir "kurulum" gönderirdi.
                state = fresh()
                state.pending = false
                state.sentAttStatus = consent.allowsAttStatus ? env.signals.attStatus() : nil
            }
            await stateful.saveAttributionState(state)
        case .unavailable:
            persistent = false
            if let memory {
                state = memory
            } else if installedWithin(Self.anonymousWindowMs) {
                state = fresh()
            } else {
                return
            }
        }

        if !state.pending {
            let route: AttributionRoute = consent.allowsIdentifiedAttribution ? .identified : .anonymous
            let status = consent.allowsAttStatus ? env.signals.attStatus() : nil
            if Self.needsNewSignal(state, route: route, status: status) {
                state = fresh()
            } else {
                if state.sentRoute == nil, state.sentAttStatus == nil, let status {
                    // Devralınan kayıt: durum ilk kez okunabildi; gönderilmez, yalnız kaydedilir.
                    state.sentAttStatus = status
                    await store(state, persistent: persistent, stateful)
                }
                return
            }
        }

        if env.nowMs() - state.firstSignalAtMs > Self.maxSignalAgeMs {
            state.insertId = env.uuid()
            state.firstSignalAtMs = env.nowMs()
        }

        var c = Attribution.collect(consent: consent, signals: env.signals)
        if c.tokenTransient, state.attempts + 1 >= Self.transientTokenLimit {
            // Token üretimi kalıcı olarak düşüyor: ATT durumu/IDFA token'sız gitsin.
            c.tokenTransient = false
        }
        if c.tokenTransient {
            state.attempts += 1
            await store(state, persistent: persistent, stateful)
            scheduleRetry()
            return
        }
        guard !c.fields.isEmpty else {
            // Gönderilecek hiçbir şey yok (tvOS, rızasız ve token'sız): bekleme kapanır.
            state.pending = false
            state.sentRoute = Self.routeName(c.route)
            await store(state, persistent: persistent, stateful)
            return
        }

        let result = await stateful.deliver(
            c.route, c.fields, envelope: AttributionEnvelope(insertId: state.insertId, timeMs: state.firstSignalAtMs))
        switch result {
        case .sent, .rejected:
            // Reddedilen gövde tekrar denenerek düzelmez; aynı durumla yeniden gönderilmesin.
            state.pending = false
            state.attempts += 1
            state.sentAttStatus = c.status
            state.sentRoute = Self.routeName(c.route)
            backoffStep = 0
            await store(state, persistent: persistent, stateful)
        case .stopped:
            // Bu deneme sürerken yeni bir `start` geldiyse onun kararı geçerlidir.
            if gen == generation { stopped = true }
        case .retryLater:
            state.attempts += 1
            await store(state, persistent: persistent, stateful)
            scheduleRetry()
        }
    }

    #if DEBUG
    func debugSendFresh(sink: AttributionSink, consent: Consent) async {
        guard let stateful = sink as? AttributionStateSink else { return }
        let c = Attribution.collect(consent: consent, signals: env.signals)
        guard !c.tokenTransient, !c.fields.isEmpty else { return }
        _ = await stateful.deliver(
            c.route, c.fields, envelope: AttributionEnvelope(insertId: env.uuid(), timeMs: env.nowMs()))
    }
    #endif

    /// Gönderilmiş sinyalden sonra yeni sinyal gerekir mi (SPEC §8.2, ATT değişimi).
    static func needsNewSignal(_ s: AttributionState, route: AttributionRoute, status: String?) -> Bool {
        // Kimliksiz gitmiş sinyal, rıza kimlikli yolu açınca kimlikli olarak yeniden gider.
        if route == .identified, s.sentRoute == routeName(.anonymous) { return true }
        guard let status else { return false }
        if let sent = s.sentAttStatus { return sent != status }
        // Durumsuz gitmiş (rıza durumu okumaya izin vermiyordu) ve şimdi okunabiliyor: rıza genişledi.
        // Devralınan kayıtta (`sentRoute == nil`) gönderilmez.
        return s.sentRoute != nil
    }

    /// Kurulum bu süreden genç mi. Kurulum anı bilinmiyorsa `true` (sinyal kaybolmasın).
    private func installedWithin(_ windowMs: Int64) -> Bool {
        guard let installed = env.installedAtMs() else { return true }
        return env.nowMs() - installed <= windowMs
    }

    /// Uygulama kabının `Library` dizininin oluşturulma anı. Salt okuma; hiçbir iz bırakmaz.
    static func liveInstalledAtMs() -> Int64? {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
              let date = (try? lib.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func fresh() -> AttributionState {
        AttributionState(pending: true, insertId: env.uuid(), firstSignalAtMs: env.nowMs())
    }

    private func store(_ s: AttributionState, persistent: Bool, _ sink: AttributionStateSink) async {
        memory = s
        if persistent { await sink.saveAttributionState(s) }
    }

    private func scheduleRetry() {
        guard backoffStep < env.backoff.count, !retryPending else { return }
        let delay = env.backoff[backoffStep]
        backoffStep += 1
        retryPending = true
        let sleep = env.sleep
        retryTask = Task { [weak self] in
            await sleep(delay)
            await self?.retryFired()
        }
    }

    private func retryFired() async {
        retryPending = false
        await attempt()
    }

    static func routeName(_ r: AttributionRoute) -> String {
        switch r {
        case .identified: return "identified"
        case .anonymous: return "anonymous"
        }
    }

    /// Üretimde ön plan bildirimi (çekirdeğin `LifecycleObserver`'ı ile aynı ad). Gözlemci bildirim
    /// merkezinden kapanımla kaydolur; dönen nesne tutuldukça dinler.
    static let liveForegroundObserver: @Sendable (@escaping @Sendable () -> Void) -> AnyObject? = { handler in
        #if canImport(UIKit) && !os(watchOS)
        let name = UIApplication.didBecomeActiveNotification
        return NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
        #elseif canImport(AppKit)
        let name = NSApplication.didBecomeActiveNotification
        return NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
        #else
        return nil
        #endif
    }
}

import Foundation

// MARK: - Actor sınırını geçen property değeri

/// Props `Any` taşır ve `Any` **`Sendable` değildir**; `PropertyOps` da bu yüzden `Sendable`
/// değil (Görev 4 kararı). Public API ise her thread'den çağrılabiliyor, `actor Core` ise
/// izole: aradaki sınırı geçecek bir değer tipi gerekiyor.
///
/// `PropValue`, `EventJSON.sanitize`'ın `Sendable` aynasıdır: dönüşüm **çağıranın thread'inde**,
/// diske/ağa dokunmadan yapılır ve ortaya yalnız JSON'da karşılığı olan değerler çıkar.
/// Tel üzerindeki biçimin tek yazarı yine `EventJSON`'dur; `PropValue` sadece gönderilebilirliği
/// garanti eder (`json` çıktısı `sanitize`'dan değişmeden geçer).
enum PropValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    indirect case list([PropValue])
    indirect case map([String: PropValue])

    static func from(_ value: Any?) -> PropValue {
        guard let value else { return .null }
        // Optional açık açılır: açılmayan `.some(x)` default dalda "Optional(x)" metnine dönerdi.
        if Mirror(reflecting: value).displayStyle == .optional {
            guard let wrapped = Mirror(reflecting: value).children.first?.value else { return .null }
            return from(wrapped)
        }
        switch value {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            // Swift Bool/Int/Double hepsi NSNumber'a köprülenir; tek dal yeter.
            // CFBoolean ayrı tutulmazsa `true` 1'e düşerdi.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            guard n.doubleValue.isFinite else { return .null }   // JSON'da NaN/Infinity yok
            return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.int64Value)
        case let d as [String: Any?]:
            return .map(d.mapValues { from($0) })
        case let a as [Any?]:
            return .list(a.map { from($0) })
        case let d as Date:
            // Protokoldeki `time` ile aynı birim (epoch ms). Aralık dışı tarih metne düşer:
            // `Int64(Double)` taşmada trap eder ve ev sahibini çökertirdi.
            let ms = (d.timeIntervalSince1970 * 1000).rounded()
            if let exact = Int64(exactly: ms) { return .int(exact) }
            return .string(String(describing: d))
        case let u as URL:
            return .string(u.absoluteString)
        default:
            // Android bilinmeyen tipte `toString()` yazar; `null` görünmez veri kaybı olurdu.
            return .string(String(describing: value))
        }
    }

    /// `EventJSON`'un beklediği düz değer.
    var json: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .list(let a): return a.map(\.json)
        case .map(let m): return m.mapValues(\.json)
        }
    }

    static func props(_ raw: [String: Any]?) -> [String: PropValue]? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.mapValues { from($0) }
    }

    static func map(_ raw: [String: Any]) -> [String: PropValue] {
        raw.mapValues { from($0) }
    }

    static func wire(_ values: [String: PropValue]?) -> [String: Any?]? {
        guard let values, !values.isEmpty else { return nil }
        return values.mapValues { $0.json as Any? }
    }
}

// MARK: - Yaşam döngüsü durumunun yeri

/// Yaşam döngüsü durumunun **kalıcı** konumu.
///
/// Neden `Platform.queueDirectory` DEĞİL: tvOS'ta o dizin bilerek `Caches`'tir (sistem onu
/// istediğinde boşaltır). Durum oraya konsaydı Caches her boşaldığında `cz_app_installed`
/// tekrar ederdi — yani kurulum metriği şişerdi. Kuyruğun kaybı tolere edilebilir, kurulum
/// sayısının bozulması edilemez; bu yüzden ikisi aynı yerde durmaz.
struct LifecycleLocation: Sendable {
    let url: URL
    let usesDefaults: Bool
}

// MARK: - user_id deposu

/// `identify()` ile bağlanan `user_id`'nin kalıcı deposu (`DeviceIdStore` ile aynı kalıp:
/// iOS/macOS dosya, tvOS `UserDefaults`).
///
/// Kalıcı olmak zorunda: `distinct_id` `identify()`den sonra `user_id`'dir (SPEC §2) ve
/// uygulama yeniden açıldığında aynı kullanıcı anonim görünürse oturum/DAU ikiye bölünür.
struct IdentityStore: Sendable {
    let platform: Platform
    let defaultsSuite: String?

    static let defaultsKey = "cz_user_id"

    private var usesDefaults: Bool { platform.name == "tvos" }
    private var file: URL { platform.queueDirectory.appendingPathComponent("user_id") }
    private var defaults: UserDefaults { defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    /// Salt okuma: dizin ya da dosya yaratmaz.
    func read() -> String? {
        if usesDefaults {
            let s = defaults.string(forKey: Self.defaultsKey)
            return (s?.isEmpty ?? true) ? nil : s
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    func write(_ id: String) -> Bool {
        if usesDefaults {
            defaults.set(id, forKey: Self.defaultsKey)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(id.utf8).write(to: file, options: .atomic)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    func clear() {
        if usesDefaults {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Bekleyen user property operasyonları

/// `track()`/`identify()` beklerken biriken `$set`/`$set_once`/`$add`/`$unset`.
///
/// Kural (Android'in Important bulgusu): **yazma başarısız olursa bekleyenler SİLİNMEZ.**
/// `take()` yalnız satır gerçekten kuyruğa girdikten sonra çağrılır.
struct Pending: Sendable {
    var setMap: [String: PropValue] = [:]
    var setOnceMap: [String: PropValue] = [:]
    var addMap: [String: Double] = [:]
    var unsetKeys: [String] = []

    var isEmpty: Bool { setMap.isEmpty && setOnceMap.isEmpty && addMap.isEmpty && unsetKeys.isEmpty }

    func ops() -> PropertyOps {
        PropertyOps(
            set: PropValue.wire(setMap),
            setOnce: PropValue.wire(setOnceMap),
            unset: unsetKeys.isEmpty ? nil : unsetKeys,
            add: addMap.isEmpty ? nil : addMap.mapValues { $0 as Any? })
    }
}

// MARK: - Çekirdek

/// SDK'nın tüm değişken durumunu sahiplenen actor. `EventQueue`, `SessionStore` ve
/// `Dispatcher` buradan çıkmaz; `Sendable` olmayan tipleri derleyici burada tutar.
actor Core {
    /// Enjekte edilebilir çevre. Üretimde `Cizeylem.initialize` ana aktörde doldurur.
    struct Dependencies: Sendable {
        var platform: Platform = .current
        /// IDFV özeti; ana thread'de **bir kez** okunup değer olarak geçer (Görev 2 kararı).
        var vendorHash: String?
        var device = DeviceSnapshot(isPad: false, screenWidth: nil, screenHeight: nil)
        var app = AppInfo()
        var installSource: String?
        /// `start()` sırasında uygulama zaten ön plandaysa `true` (ilk `cz_app_opened` kaybolmasın).
        var startsActive = false
        /// Context'teki başlangıç `app_state` değeri.
        var appState = "background"
        var notificationCenter: NotificationCenter = .default
        var defaultsSuite: String?
        /// `nil` ise `Core.lifecycleLocation(platform:defaultsSuite:)`.
        var lifecycle: LifecycleLocation?
        /// `nil` ise Amplitude'un üretimdeki varsayılan dizini.
        var amplitudeLibraryDirectory: URL?
        /// Testte devralma kaynağını taklit etmek için; üretimde `nil`.
        var takeoverOverride: Takeover?
        /// Duvar saati, epoch saniye.
        var now: @Sendable () -> Double = { Date().timeIntervalSince1970 }
        var uuid: @Sendable () -> String = { UUID().uuidString }
        var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
        var sleep: @Sendable (TimeInterval) async -> Void = { seconds in
            guard seconds > 0, seconds.isFinite, seconds < 86_400 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        var network: @Sendable () -> String? = { nil }
        var consentReadFile: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var deviceIdReadFile: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var makeTransport: @Sendable (Configuration) -> BatchSending = { config in
            let session = URLSession(configuration: Core.sessionConfiguration())
            return Transport(endpoint: config.endpoint, apiKey: config.writeKey, session: session)
        }
    }

    private enum LifeSignal: Sendable {
        case event(String, [String: PropValue])
        case flush
    }

    private let config: Configuration
    private let deps: Dependencies
    private let flushAtValue: Int
    private let consentStore: ConsentStore
    private let deviceIdStore: DeviceIdStore
    private let identityStore: IdentityStore
    private let context: ContextProvider
    private let location: LifecycleLocation

    private var consent = Consent()
    private var started = false
    private var dispatcher: Dispatcher?
    private var session: SessionStore?
    private var deviceId: String?
    private var deviceIdUnavailable = false
    private var userId: String?
    private var pending = Pending()
    private var observer: LifecycleObserver?
    private var lifeFeed: AsyncStream<LifeSignal>.Continuation?
    private var lifeTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var appState: String
    private var existingInstall = false
    private var loggedDisabled = false
    /// Bu SÜREÇTE açık bir `setConsent` ile her şeyi sildik mi (bkz. `erase()`).
    ///
    /// Neden gerekli: `erase()` bizim depomuzu siler ama **Amplitude'un deposunu silemez**
    /// (kural: Amplitude kaydına dokunulmaz). Rıza geri verilince devralma zinciri baştan
    /// koşsaydı aynı eski `device_id` yeniden benimsenir, yani açık "beni unut" talebi boşa
    /// çıkar ve kullanıcı sunucudaki eski profiline yeniden bağlanırdı.
    ///
    /// Kalıcı bir "unut" işareti YAZAMAYIZ: rızasızken hiçbir iz bırakmama kuralı bunu yasaklar.
    /// Bu yüzden işaret süreç ömrüyle sınırlı; rıza geri gelir gelmez taze bir kimlik üretip
    /// **kalıcı yazarız** ve sonraki süreçler kendi depomuzu gördüğü için devralma bir daha hiç
    /// tetiklenmez — düzeltme kalıcı olur, bayrak yalnız aradaki boşluğu kapatır.
    ///
    /// Bayrak yalnız **silinecek bir şey varken** kurulur (bkz. `erase`): hiç veri
    /// toplanmamışken unutulacak bir şey de yoktur.
    ///
    /// **Kalan açık:** süreç, `erase()` ile rızanın yeniden verilmesi arasında ölürse bayrak
    /// kaybolur ve devralma bir kez daha koşar. Kalıcı iz bırakmadan kapatılamıyor.
    private var erasedInProcess = false

    init(config: Configuration, deps: Dependencies) {
        self.config = config
        self.deps = deps
        self.flushAtValue = max(1, config.flushAt ?? deps.platform.flushAt)
        self.appState = deps.appState
        self.location = deps.lifecycle
            ?? Core.lifecycleLocation(platform: deps.platform, defaultsSuite: deps.defaultsSuite)
        self.consentStore = ConsentStore(
            platform: deps.platform, defaultsSuite: deps.defaultsSuite, readFile: deps.consentReadFile)
        self.deviceIdStore = DeviceIdStore(
            platform: deps.platform, vendorHash: deps.vendorHash, uuid: deps.uuid,
            defaultsSuite: deps.defaultsSuite, readFile: deps.deviceIdReadFile)
        self.identityStore = IdentityStore(platform: deps.platform, defaultsSuite: deps.defaultsSuite)
        self.context = ContextProvider(
            libVersion: Cizeylem.version, platform: deps.platform, device: deps.device,
            app: deps.app, installSource: deps.installSource, network: deps.network)
    }

    /// Yaşam döngüsü durumu kuyruk dizininden **bağımsız** ve kalıcı bir yerde durur
    /// (tvOS'ta `UserDefaults`). Gerekçe `LifecycleLocation`'da.
    static func lifecycleLocation(platform: Platform, defaultsSuite: String?) -> LifecycleLocation {
        let fm = FileManager.default
        // `urls(for:)` dizin yaratmaz: rızasızken bu çağrı iz bırakmaz.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return LifecycleLocation(
            url: base.appendingPathComponent("Cizeylem", isDirectory: true)
                .appendingPathComponent("lifecycle"),
            usesDefaults: platform.name == "tvos")
    }

    /// `timeoutInterval` **boşta kalma** süresidir, toplam değil (Görev 5 notu): toplam sınır
    /// burada kurulur, yoksa çok yavaş bir bağlantıda istek süresiz sürüklenirdi.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return c
    }

    // MARK: - Yaşam döngüsü

    /// Rızayı diskten **bir kez** okur ve rıza varsa kalıcı katmanı kurar.
    ///
    /// Rıza yoksa hiçbir şey kurulmaz: ne kuyruk dizini, ne `device_id`, ne gözlemci.
    /// `ConsentStore.read()` "okunamadı" ile "geri alındı" ayrımını yapmaz ve ikisi de
    /// üçü-kapalı döner — bu yüzden buradan **silme kararı çıkmaz** (bkz. `setConsent`).
    func start() async {
        guard !started else { return }
        started = true
        consent = consentStore.read()
        guard consent.allowsWrite else { return }
        await enable()
    }

    func shutdown() {
        timerTask?.cancel()
        timerTask = nil
        lifeFeed?.finish()
        lifeFeed = nil
        lifeTask?.cancel()
        lifeTask = nil
        observer = nil
        dispatcher = nil
        session = nil
    }

    private func enable() async {
        guard dispatcher == nil else { return }
        adoptExistingIdentity()
        // Aynı süreçte sildiysek uygulama yeniden KURULMADI; durumu önceden yazarız ki gözlemci
        // "ilk açılış" sanıp ikinci bir `cz_app_installed` üretmesin (kurulum metriği şişmesin).
        // Bu yazım rıza geri verildikten SONRA olur, yani rızasız iz bırakma kuralını bozmaz.
        if erasedInProcess { await seedLifecycleState() }
        userId = identityStore.read()
        let queue = EventQueue(
            directory: deps.platform.queueDirectory,
            maxEvents: deps.platform.maxEvents, maxBytes: deps.platform.maxBytes)
        dispatcher = Dispatcher(
            queue: queue, transport: deps.makeTransport(config), now: deps.now, random: deps.random)
        session = SessionStore(
            url: deps.platform.queueDirectory.appendingPathComponent("session"), now: deps.now)
        startLifecycle()
        startTimer()
    }

    /// SPEC §6 devralma zinciri. Yalnız kendi depomuz boşken çalışır: aksi halde
    /// `migrated_from` her açılışta yeniden tetiklenirdi.
    private func adoptExistingIdentity() {
        guard deviceIdStore.read() == nil else { return }

        // Açık geri almadan sonra devralma ZİNCİRİ HİÇ KOŞMAZ: aksi halde sildiğimiz kimlik
        // Amplitude'un (silemediğimiz) deposundan geri gelirdi. Yerine taze anonim kimlik.
        if erasedInProcess {
            mintFreshIdentity()
            return
        }

        // 1. Açık `Configuration(deviceId:)` — geliştiricinin bilinçli seçimi, `legacyAmplitude`
        //    bayrağından bağımsızdır (o bayrak yalnız Amplitude'u OKUMAYI kapatır).
        if let explicit = config.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            apply(Takeover(deviceId: explicit, source: "configured", optOut: false))
            return
        }
        guard config.legacyAmplitude else { return }

        // 2-4. Amplitude (salt okuma).
        let found: Takeover?
        if let override = deps.takeoverOverride {
            found = override
        } else if let dir = deps.amplitudeLibraryDirectory {
            found = AmplitudeTakeover.find(
                apiKey: config.writeKey, configured: nil, instance: "",
                ownStore: deviceIdStore, libraryDirectory: dir)
        } else {
            found = AmplitudeTakeover.find(apiKey: config.writeKey, configured: nil)
        }
        guard let found else { return }
        apply(found)
    }

    /// Geri alma sonrası taze anonim kimlik. Kalıcı yazılır: sonraki süreçler kendi depomuzu
    /// görür ve devralma bir daha tetiklenmez.
    private func mintFreshIdentity() {
        let fresh = deps.uuid()
        deviceIdStore.write(fresh)
        guard deviceIdStore.read() == fresh else {
            // Yazılamadı. Bayrak duruyor, yani devralmaya DÖNÜLMEZ — yazamamak, silinmiş
            // kimliği geri getirmek için gerekçe değildir. Kurtarma `enable()`'dan değil
            // `ensureDeviceId()`'den gelir: ilk event denemesinde `getOrCreate()` yeniden dener.
            // Durum madde 2'deki yolla görünür olsun diye şimdi işaretlenir, yoksa ilk
            // sorguya kadar `stats()` iyimser kalırdı.
            deviceIdUnavailable = true
            warn("geri alma sonrası taze kimlik yazılamadı; ilk event denemesinde tekrarlanacak")
            return
        }
        deviceId = fresh
    }

    private func apply(_ takeover: Takeover) {
        deviceIdStore.write(takeover.deviceId)
        // Devralınan kimlik diske YAZILAMADIYSA devralma olmamış sayılır: `migrated_from`
        // gönderip kimliği kaybetmek iki raporu da yanıltır.
        guard deviceIdStore.read() == takeover.deviceId else {
            warn("devralınan device_id yazılamadı; devralma atlandı")
            return
        }
        deviceId = takeover.deviceId
        existingInstall = true
        pending.setOnceMap["migrated_from"] = .string(takeover.source)
        // Amplitude'un `optOut` bayrağı rızayı KAPATMAZ: koruma mekanizması zaten
        // "üç anahtar da varsayılan kapalı" olmasıdır. Host açıkça `setConsent(analytics: true)`
        // dediyse bu TAZE iradedir ve aylar önce başka bir SDK'da bırakılmış bir bayrak onu
        // ezemez. Bilgi yine de kaybolmasın diye ilk event'e `$set_once` ile iliştirilir;
        // panelde bu kullanıcılar ayırt edilebilir kalır.
        if takeover.optOut { pending.setOnceMap["migrated_opt_out"] = .bool(true) }
    }

    /// Yaşam döngüsü durumunu "bu sürüm zaten kurulu" diye işaretler.
    private func seedLifecycleState() async {
        let store = LifecycleStateStore(
            url: location.url, usesDefaults: location.usesDefaults, defaultsSuite: deps.defaultsSuite)
        let snapshot = LifecycleSnapshot(version: deps.app.version, build: deps.app.build)
        guard !store.save(snapshot) else { return }
        // Yazım düştüyse `launch()` kaydı `.absent` görür ve yine ikinci bir `cz_app_installed`
        // üretirdi. Süreç belleği bu yolu da kapatır (`LifecycleObserver.record()` ile aynı kalıp).
        await UnpersistedLifecycle.shared.set(store.key, snapshot)
    }

    private func startLifecycle() {
        guard observer == nil else { return }   // tek gözlemci örneği (Görev 9 → madde 19)
        let (stream, feed) = AsyncStream<LifeSignal>.makeStream(bufferingPolicy: .unbounded)
        lifeFeed = feed
        // Sinyaller TEK bir tüketicide, geliş sırasıyla işlenir. Her bildirimi ayrı bir
        // `Task` ile actor'e göndermek sırayı bozar ve `cz_app_opened`, `cz_app_installed`'dan
        // önce gidebilirdi.
        lifeTask = Task { [weak self] in
            for await signal in stream {
                guard let self else { return }
                await self.handle(signal)
            }
        }
        // Kapanımlar `self`i DEĞİL yalnız akışı yakalar: gözlemci → kapanım → Core döngüsü olmaz.
        let observer = LifecycleObserver(
            notificationCenter: deps.notificationCenter,
            stateURL: location.url,
            app: deps.app,
            existingInstall: existingInstall,
            startsActive: deps.startsActive,
            usesDefaults: location.usesDefaults,
            defaultsSuite: deps.defaultsSuite,
            onEvent: { name, props in feed.yield(.event(name, PropValue.map(props))) },
            onBackground: { feed.yield(.flush) })
        self.observer = observer
        observer.start()
    }

    private func handle(_ signal: LifeSignal) async {
        switch signal {
        case .event(let name, let props):
            // `app_state` event'ten ÖNCE güncellenir ki event kendi yeni durumunu taşısın.
            if name == "cz_app_opened" { appState = "foreground" }
            if name == "cz_app_backgrounded" { appState = "background" }
            await track(name, props)
        case .flush:
            await flush()
        }
    }

    private func startTimer() {
        guard timerTask == nil, config.flushInterval > 0 else { return }
        let interval = config.flushInterval
        let sleeper = deps.sleep
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleeper(interval)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.flush()
            }
        }
    }

    // MARK: - Rıza

    /// **Açık** rıza kararı. Silme kararı YALNIZ buradan çıkar (Görev 7 tuzağı): `read()`
    /// sonucuna bakarak silmek, kilitli cihazda geçici bir okuma hatasında kullanıcı verisini
    /// yok ederdi.
    func setConsent(_ next: Consent) async {
        if !started { started = true }
        let previous = consent
        // Bellekteki rıza her durumda güncellenir: diske yazılamasa bile bu süreçte host'un
        // iradesi geçerlidir (daraltmada daha kısıtlayıcı, genişletmede host zaten istiyor).
        consent = next
        if !consentStore.write(next) {
            // `ConsentStore` yazamadığında kaydı SİLER; böylece sonraki süreç rızasız başlar ve
            // host rızayı yeniden sorar. Eski (geniş) kaydın diriltilmesi hukuken kabul edilemez.
            warn("rıza diske yazılamadı; kayıt silindi, sonraki süreç rızasız başlayacak")
        }
        if next.allowsWrite {
            await enable()
        } else {
            // Önceki rıza da kapalı olsa silinir: bu AÇIK bir "rıza yok" beyanıdır ve bir okuma
            // hatasından sonra kalmış olabilecek kayıtları da götürmesi gerekir. `previous`
            // yalnız "unutulacak bir şey var mıydı" sorusu için taşınır (bkz. `erase`).
            erase(previouslyAllowedWrite: previous.allowsWrite)
        }
    }

    /// Geriye uyumluluk API'si, **en dar yorum**:
    /// - `true`: üç anahtarı da kapatır.
    /// - `false`: YALNIZ `analytics`'i açar. `attribution`/`adSharing` varsayılmaz — eski tekil
    ///   `optOut` bayrağı bu iki ayrı iradeyi hiçbir zaman taşımıyordu, onları "verilmiş"
    ///   saymak kullanıcı adına rıza uydurmak olurdu. Geniş rıza için `setConsent` kullanılır.
    func setOptOut(_ optOut: Bool) async {
        await setConsent(optOut ? Consent() : Consent(analytics: true))
    }

    /// Rızasız kullanıcıda bizden iz kalmaz: kuyruk, kimlik, oturum ve yaşam döngüsü durumu silinir.
    ///
    /// - Parameter previouslyAllowedWrite: Bu çağrıdan hemen öncesinde rıza yazmaya izin
    ///   veriyor muydu.
    private func erase(previouslyAllowedWrite: Bool) {
        // "Devralmayı bir daha koşturma" bayrağı yalnız SİLİNECEK BİR ŞEY varken kurulur.
        // İlke: hiç veri toplanmamışken unutulacak bir şey de yoktur. Taze kurulumda host'un
        // savunma amaçlı `setOptOut(true)` çağrısı (desteklenen bir kalıp), hiç başlamamış bir
        // Amplitude devralmasını ya da geliştiricinin açıkça verdiği `Configuration(deviceId:)`
        // değerini KALICI olarak iptal etmemeli — bu, madde 4'ün ve devralma işinin amacını
        // boşa çıkarırdı. Kontrol silmeden ÖNCE yapılır.
        if previouslyAllowedWrite || deviceIdStore.read() != nil { erasedInProcess = true }
        shutdown()
        deviceId = nil
        userId = nil
        pending = Pending()
        existingInstall = false
        deviceIdUnavailable = false
        loggedDisabled = false

        let fm = FileManager.default
        // Tüm kalıcı izler aynı dizinde: kuyruk, device_id, vendor_hash, oturum, user_id, rıza.
        try? fm.removeItem(at: deps.platform.queueDirectory)
        // tvOS'ta aynı kayıtlar `UserDefaults`'ta.
        let defaults = deps.defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        for key in [
            DeviceIdStore.defaultsIdKey, DeviceIdStore.defaultsHashKey,
            IdentityStore.defaultsKey, ConsentStore.defaultsKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        // Yaşam döngüsü durumu kuyruk dizininden BAĞIMSIZ konumlanır (tvOS'ta `UserDefaults`,
        // iOS/macOS'ta aynı Application Support dizini); her iki yolda da ayrıca silinir.
        if location.usesDefaults {
            defaults.removeObject(forKey: LifecycleStateStore.defaultsKey)
        } else {
            try? fm.removeItem(at: location.url)
        }
    }

    // MARK: - Event'ler

    func track(_ name: String, _ props: [String: PropValue]? = nil) async {
        await enqueue(name: name, props: props, eventUserId: nil, extraSet: nil)
    }

    /// Anonim kimliği `user_id`'ye bağlar: `$identify` ESKİ `distinct_id` ile gider, sonrası
    /// `user_id` ile (SPEC §2, `bir-js` `client.ts` ile aynı).
    func identify(_ newUserId: String, _ props: [String: PropValue]? = nil) async {
        guard consent.allowsWrite else { return }
        // `user_id` YALNIZ `$identify` gerçekten kuyruğa girdiyse benimsenir. Kimlik
        // elde edilemediğinde (veri koruması kilidi) sessizce benimsemek, eski anonim
        // `distinct_id` ile `user_id` arasındaki bağı KALICI olarak koparırdı: sonraki
        // event'ler `user_id` ile gider, bağı kuracak `$identify` ise hiç üretilmemiştir
        // ve kullanıcının anonim geçmişi sunucuda öksüz kalır.
        guard await enqueue(name: "$identify", props: nil, eventUserId: newUserId, extraSet: props) else {
            warn("identify: event üretilemedi, user_id benimsenmedi; bağ bir sonraki çağrıda kurulacak")
            return
        }
        userId = newUserId
        identityStore.write(newUserId)
    }

    func setUserProperties(_ props: [String: PropValue]) {
        pending.setMap.merge(strip(props, "$set")) { _, new in new }
    }

    func setUserPropertiesOnce(_ props: [String: PropValue]) {
        pending.setOnceMap.merge(strip(props, "$set_once")) { _, new in new }
    }

    /// Artışlar birikir (`bir-js` ile aynı): iki `addUserProperties(["n": 1])` tek event'te `2` gider.
    func addUserProperties(_ props: [String: Double]) {
        for (k, v) in strip(props, "$add") {
            pending.addMap[k] = (pending.addMap[k] ?? 0) + v
        }
    }

    func unsetUserProperties(_ keys: [String]) {
        for key in keys where !dropDollar(key, "$unset") {
            pending.unsetKeys.append(key)
        }
    }

    /// Biriken operasyonları bir sonraki event'i beklemeden `$identify` olarak gönderir.
    /// Anonim kullanıcıda da çalışır (`user_id` opsiyoneldir).
    func sendUserProperties(userId newUserId: String?) async {
        guard consent.allowsWrite else { return }
        guard !pending.isEmpty || newUserId != nil else { return }
        // `identify()` ile aynı kural: bağ kurulamadıysa `user_id` benimsenmez.
        guard await enqueue(name: "$identify", props: nil, eventUserId: newUserId, extraSet: nil) else {
            warn("sendUserProperties: event üretilemedi, user_id benimsenmedi")
            return
        }
        guard let newUserId else { return }
        userId = newUserId
        identityStore.write(newUserId)
    }

    func handleDeepLink(_ url: URL) async {
        let params = DeepLink.params(url).mapValues { PropValue.string($0) }
        await track("cz_deep_link_opened", params.isEmpty ? nil : params)
    }

    /// `reset()`: yeni anonim UUID, sunucuya çağrı yok (SPEC §2).
    func reset() async {
        guard consent.allowsWrite else { return }
        userId = nil
        identityStore.clear()
        // `reset()` "bu kullanıcıyı unut" demektir ve burada bir KULLANICI SINIRI vardır:
        // eski kullanıcının bekleyen `$set`/`$set_once`/`$add`/`$unset` operasyonlarını yeni
        // anonim kimliğe yazmak kullanıcılar arası veri sızıntısı olurdu. `bir-js` bunları
        // temizlemiyor (aynı kusur orada da var); bilinçli sapma.
        pending = Pending()
        let fresh = deps.uuid()
        deviceIdStore.write(fresh)
        if deviceIdStore.read() != fresh {
            // Bellekteki kimlik yine de yenilenir: kullanıcı çıkış yaptı, bu süreçte eski kimliğe
            // event yazmak çıkış iradesini yok sayardı.
            warn("reset: yeni anonim kimlik diske yazılamadı, yalnız bu süreçte geçerli")
        }
        deviceId = fresh
        deviceIdUnavailable = false
        // Oturum da sıfırlanır: yeni kullanıcı eskinin oturumunu sürdürmez.
        session?.reset()
    }

    func flush() async {
        guard let dispatcher else { return }
        await dispatcher.drain()
        if await dispatcher.isDisabled, !loggedDisabled {
            loggedDisabled = true
            warn("yazma anahtarı reddedildi (401/403): SDK durduruldu, event gönderilmeyecek")
        }
    }

    func distinctId() -> String? {
        if let userId { return userId }
        guard consent.allowsWrite else { return nil }
        return ensureDeviceId()
    }

    func flushAt() -> Int { flushAtValue }

    func stats() async -> Stats {
        guard let dispatcher else {
            return Stats(
                queued: 0, dropped: 0, rejected: 0, skipped: 0, disabled: false,
                deviceIdAvailable: !deviceIdUnavailable, consent: consent, running: false)
        }
        let s = await dispatcher.stats()
        return Stats(
            queued: s.queued, dropped: s.dropped, rejected: s.rejected,
            skipped: await dispatcher.skippedCount(), disabled: s.disabled,
            deviceIdAvailable: !deviceIdUnavailable, consent: consent, running: true)
    }

    // MARK: - Kuyruğa yazma

    /// Satır gerçekten kuyruğa girdiyse `true`. Çağıran bunu kimlik bağını kurup kurmayacağına
    /// karar vermek için kullanır: üretilmeyen bir `$identify` için `user_id` benimsenirse eski
    /// anonim `distinct_id` ile yeni `user_id` arasındaki bağ KALICI olarak kaybolur.
    @discardableResult
    private func enqueue(
        name: String, props: [String: PropValue]?, eventUserId: String?, extraSet: [String: PropValue]?
    ) async -> Bool {
        guard consent.allowsWrite else { return false }
        guard let dispatcher, let session else { return false }
        // Bu üç çıkış da bekleyenleri KORUR (madde 3): `pending` yalnız satır kuyruğa
        // girdikten sonra boşaltılır.
        guard let id = ensureDeviceId() else { return false }

        var ops = pending
        if let extraSet {
            // `bir-js` burada bekleyen `$set`'i props ile EZİYOR (nesne literal sırası yüzünden).
            // Birleştiriyoruz: çakışan anahtarda props kazanır, bekleyenler SESSİZCE KAYBOLMAZ.
            ops.setMap.merge(strip(extraSet, "$set")) { _, new in new }
        }

        let line = EventJSON.event(
            name: name,
            distinctId: userId ?? id,
            time: milliseconds(deps.now()),
            insertId: deps.uuid(),
            sessionId: session.current(),
            props: PropValue.wire(strip(props ?? [:], "props")),
            ops: ops.ops(),
            userId: eventUserId,
            context: context.get(consent: consent, appState: appState, attStatus: nil)
                .mapValues { $0 as Any? })

        guard !line.isEmpty else {
            warn("event serileştirilemedi, atlandı: \(name)")
            return false
        }
        pending = Pending()
        await dispatcher.enqueue(line)
        if await dispatcher.stats().queued >= flushAtValue { scheduleFlush() }
        return true
    }

    /// Kimliği döner; yoksa üretmeyi dener. Üretilemezse SDK **sessizce ölmez**: durum
    /// `stats().deviceIdAvailable` ile görünür ve her çağrıda yeniden denenir (veri koruması
    /// açıldığında kendiliğinden toparlanır).
    private func ensureDeviceId() -> String? {
        if let deviceId { return deviceId }
        guard let id = deviceIdStore.getOrCreate() else {
            if !deviceIdUnavailable {
                warn("device_id okunamadı/üretilemedi (veri koruması kapalı olabilir); sonraki çağrıda yeniden denenecek")
            }
            deviceIdUnavailable = true
            return nil
        }
        deviceIdUnavailable = false
        deviceId = id
        return id
    }

    private func scheduleFlush() {
        // Eşik flush'ı BEKLENMEZ: `bir-js` de `void this.flush()` yapar. Beklenseydi ağ turu
        // boyunca sıradaki bütün API çağrıları (actor üzerinden) kuyrukta kalırdı.
        Task { [weak self] in await self?.flush() }
    }

    // MARK: - Yardımcılar

    /// Sunucu `$` önekli bir prop anahtarı görürse **bütün event'i düşürür** (Görev 4'te
    /// `EventJSON`'un değil üst katmanın işi olduğuna karar verilmişti). Tek bir yanlış
    /// anahtarın event'in tamamını götürmesindense o anahtarı atıp uyarmak daha az veri kaybettirir.
    private func strip<T>(_ map: [String: T], _ what: String) -> [String: T] {
        guard map.contains(where: { $0.key.hasPrefix("$") }) else { return map }
        var out: [String: T] = [:]
        for (k, v) in map {
            if k.hasPrefix("$") {
                warn("`$` önekli anahtar atıldı (\(what).\(k)): sunucu bu anahtarı gören event'in tamamını düşürür")
                continue
            }
            out[k] = v
        }
        return out
    }

    private func dropDollar(_ key: String, _ what: String) -> Bool {
        guard key.hasPrefix("$") else { return false }
        warn("`$` önekli anahtar atıldı (\(what).\(key)): sunucu bu anahtarı gören event'in tamamını düşürür")
        return true
    }

    /// Duvar saati, ms. Sonlu olmayan ya da Int64'e sığmayan değer 0'a düşer: dönüşüm trap eder
    /// ve ev sahibi uygulamayı çökertirdi.
    private func milliseconds(_ seconds: Double) -> Int64 {
        let ms = seconds * 1000
        guard ms.isFinite, abs(ms) < 9.0e18 else { return 0 }
        return Int64(ms)
    }

    private func warn(_ message: String) {
        config.logger?("[cizeylem] " + message)
    }
}

// MARK: - Komut hattı

/// Public API'den gelen her çağrı **tek bir sıraya** girer.
///
/// Neden: `actor` yeniden girilebilir ve her çağrıyı ayrı bir `Task` ile göndermek görev
/// başlatma sırasını korumaz — iki `track()` arasında event SIRASI bozulabilirdi. Tek bir
/// `AsyncStream` tüketicisi hem sırayı hem de "ana thread'e senkron sıçrama yok" kuralını
/// korur: çağıran yalnız `yield` eder, hiçbir şey beklemez.
final class CommandPipe: Sendable {
    enum Command: Sendable {
        case start(Configuration, Core.Dependencies)
        case track(String, [String: PropValue]?)
        case identify(String, [String: PropValue]?)
        case setUserProperties([String: PropValue])
        case setUserPropertiesOnce([String: PropValue])
        case addUserProperties([String: Double])
        case unsetUserProperties([String])
        case sendUserProperties(String?)
        case setConsent(Consent)
        case setOptOut(Bool)
        case deepLink(URL)
        case flush
        case reset
        /// Okuma sorgusu; yanıtı kendi kapanımıyla taşır. Sıraya girdiği için kendinden önceki
        /// yazmaları görmesi garantidir.
        case query(@Sendable (Core?) async -> Void)
    }

    private let feed: AsyncStream<Command>.Continuation

    init() {
        let (stream, feed) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        self.feed = feed
        Task.detached(priority: .utility) { await CommandPipe.run(stream) }
    }

    func send(_ command: Command) { feed.yield(command) }

    private static func run(_ stream: AsyncStream<Command>) async {
        // Değişken durum yalnız bu görevin yerel değişkeni: kilit ya da `@unchecked` gerekmez.
        var core: Core?
        for await command in stream {
            switch command {
            case .start(let config, let deps):
                // İkinci `initialize` yok sayılır: iki çekirdek aynı kuyruğa yazardı.
                guard core == nil else { continue }
                let fresh = Core(config: config, deps: deps)
                core = fresh
                await fresh.start()
            case .track(let name, let props): await core?.track(name, props)
            case .identify(let id, let props): await core?.identify(id, props)
            case .setUserProperties(let p): await core?.setUserProperties(p)
            case .setUserPropertiesOnce(let p): await core?.setUserPropertiesOnce(p)
            case .addUserProperties(let p): await core?.addUserProperties(p)
            case .unsetUserProperties(let keys): await core?.unsetUserProperties(keys)
            case .sendUserProperties(let id): await core?.sendUserProperties(userId: id)
            case .setConsent(let c): await core?.setConsent(c)
            case .setOptOut(let v): await core?.setOptOut(v)
            case .deepLink(let url): await core?.handleDeepLink(url)
            case .flush: await core?.flush()
            case .reset: await core?.reset()
            case .query(let answer): await answer(core)
            }
        }
    }
}

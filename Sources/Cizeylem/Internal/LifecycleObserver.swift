import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Son görülen sürümün anlık görüntüsü.
struct LifecycleSnapshot: Sendable, Equatable {
    var version: String?
    var build: String?
}

/// Durum dosyası/anahtarı. Bilerek durumsuz `struct`; hiçbir okuma iz bırakmaz.
///
/// iOS/macOS: `stateURL` dosyası, yedekten hariç, atomik yazım. tvOS: `UserDefaults` (`cz_lifecycle_state`).
struct LifecycleStateStore: Sendable {
    let url: URL
    let usesDefaults: Bool
    let defaultsSuite: String?

    static let defaultsKey = "cz_lifecycle_state"

    enum Loaded: Sendable, Equatable {
        case absent
        /// Kayıt var ama ayrıştırılamıyor (kesik/yabancı içerik).
        case corrupt
        /// Kayıt var olabilir ama okunamıyor (ör. veri koruması). "Yok" ile karıştırılmaz.
        case unreadable
        case value(LifecycleSnapshot)
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Süreç içi "yazılamayan durum" kaydının anahtarı.
    var key: String { usesDefaults ? "defaults:\(defaultsSuite ?? ""):\(Self.defaultsKey)" : url.path }

    func load() -> Loaded {
        let data: Data
        if usesDefaults {
            guard let s = defaults.string(forKey: Self.defaultsKey) else { return .absent }
            data = Data(s.utf8)
        } else {
            do {
                data = try Data(contentsOf: url)
            } catch {
                // Fail-closed (DeviceIdStore ile aynı): yalnız "dosya yok" .absent'tır. Başka her hata
                // "okunamadı"dır; aksi halde kilitli cihazda (prewarm) var olan kayıt yokmuş sanılıp
                // sahte bir cz_app_installed üretilirdi.
                return DeviceIdStore.isNoSuchFile(error) ? .absent : .unreadable
            }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .corrupt }
        var snapshot = LifecycleSnapshot()
        if let v = object["version"] { guard let s = v as? String else { return .corrupt }; snapshot.version = s }
        if let b = object["build"] { guard let s = b as? String else { return .corrupt }; snapshot.build = s }
        return .value(snapshot)
    }

    func save(_ snapshot: LifecycleSnapshot) -> Bool {
        var object: [String: String] = [:]
        if let v = snapshot.version { object["version"] = v }
        if let b = snapshot.build { object["build"] = b }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        if usesDefaults {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            var file = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}

/// Diske yazılamayan durumun süreç ömründeki belleği.
///
/// Neden: durum yazılamazsa her gözlemci "ilk açılış" görür ve `cz_app_installed` (kurulum sayısı)
/// şişer; Android'de tam bu oldu. Yalnız yazma BAŞARISIZ olduğunda dolar, başarılı yazımda silinir; bu
/// yüzden diskteki gerçek durumu hiçbir zaman gölgelemez.
///
/// Modül içi görünür: `Core` geri alma sonrası durumu tohumlarken yazım düşerse aynı belleği
/// kullanır (aksi halde ikinci bir `cz_app_installed` üretilirdi).
actor UnpersistedLifecycle {
    static let shared = UnpersistedLifecycle()
    private var entries: [String: LifecycleSnapshot] = [:]

    func get(_ key: String) -> LifecycleSnapshot? { entries[key] }
    func set(_ key: String, _ value: LifecycleSnapshot?) { entries[key] = value }
}

/// Yaşam döngüsü eventleri (SPEC §3): `cz_app_installed`, `cz_app_updated`, `cz_app_opened`,
/// `cz_app_backgrounded` (+ flush tetiği).
///
/// Ana thread kuralı: bildirimler ana thread'de gelir ama işleyici yalnız bir sinyali sıraya koyar
/// (bloklamaz, disk yok). Diskle ve event üretimiyle ilgili her şey tek bir tüketici görevinde, ana
/// thread dışında ve sinyallerin geliş sırasıyla çalışır. Değişken durum yalnız o görevin yerel
/// değişkenleridir, bu yüzden kilit ya da `@unchecked` gerekmez.
///
/// Rızasız kalıcı iz yok: `init` hiçbir şey okumaz/yazmaz/dinlemez; her şey `start()` ile başlar.
/// Rıza kapısı (gözlemciyi rıza verilene kadar hiç kurmamak) çağıranın işidir.
///
/// `NSObject` olmasının nedeni: seçici tabanlı abonelik `deinit`te tek çağrıyla (`removeObserver(self)`)
/// temizlenir; blok tabanlı abonelikte belirteçleri `Sendable` bir sınıfta saklamak gerekirdi.
final class LifecycleObserver: NSObject, Sendable {
    #if canImport(UIKit)
    static let activeName = UIApplication.didBecomeActiveNotification
    static let backgroundName = UIApplication.didEnterBackgroundNotification
    #elseif canImport(AppKit)
    static let activeName = NSApplication.didBecomeActiveNotification
    static let backgroundName = NSApplication.didResignActiveNotification
    #else
    static let activeName = Notification.Name("cz.lifecycle.active")
    static let backgroundName = Notification.Name("cz.lifecycle.background")
    #endif

    private enum Signal: Sendable { case launch, active, background }

    private struct Environment: Sendable {
        let store: LifecycleStateStore
        let app: AppInfo
        let existingInstall: Bool
        let startsActive: Bool
        let onEvent: @Sendable (String, [String: Any]) -> Void
        let onBackground: @Sendable () -> Void
    }

    private let center: NotificationCenter
    private let signals: AsyncStream<Signal>.Continuation

    /// - Parameters:
    ///   - existingInstall: Amplitude devralması olduysa `true` (`cz_app_installed` alanı).
    ///   - startsActive: `start()` uygulama zaten ön plandayken çağrılıyorsa `true`; `didBecomeActive`
    ///     SDK kurulmadan önce geçmiş olabilir ve ilk `cz_app_opened` aksi halde kaybolurdu.
    ///   - usesDefaults: tvOS'ta durum `UserDefaults`'ta tutulur (`Platform` kalıbı).
    init(
        notificationCenter: NotificationCenter,
        stateURL: URL,
        app: AppInfo = .main,
        existingInstall: Bool = false,
        startsActive: Bool = false,
        usesDefaults: Bool = Platform.current.name == "tvos",
        defaultsSuite: String? = nil,
        onEvent: @escaping @Sendable (String, [String: Any]) -> Void,
        onBackground: @escaping @Sendable () -> Void
    ) {
        let (stream, continuation) = AsyncStream<Signal>.makeStream()
        let env = Environment(
            store: LifecycleStateStore(url: stateURL, usesDefaults: usesDefaults, defaultsSuite: defaultsSuite),
            app: app, existingInstall: existingInstall, startsActive: startsActive,
            onEvent: onEvent, onBackground: onBackground)
        self.center = notificationCenter
        self.signals = continuation
        super.init()
        // Tüketici `self`i tutmaz: akış `deinit`te biter ve görev, kapanımlarla birlikte serbest kalır.
        Task.detached(priority: .utility) { await Self.run(stream, env) }
    }

    deinit {
        center.removeObserver(self)
        signals.finish()
    }

    /// Tekrar çağrılabilir: ilk sinyal dışındakiler yok sayılır ve abonelik çiftlenmez.
    func start() {
        // Sıra önemli: `launch` ilk sinyal olmalı ki `installed`, ilk `opened`'dan önce gelsin.
        signals.yield(.launch)
        center.removeObserver(self)
        center.addObserver(self, selector: #selector(didBecomeActive), name: Self.activeName, object: nil)
        center.addObserver(self, selector: #selector(didGoBackground), name: Self.backgroundName, object: nil)
    }

    @objc private func didBecomeActive() { signals.yield(.active) }
    @objc private func didGoBackground() { signals.yield(.background) }

    // MARK: - Tüketici

    private enum Phase { case unknown, active, background }

    private static func run(_ stream: AsyncStream<Signal>, _ env: Environment) async {
        var phase = Phase.unknown
        var launched = false
        for await signal in stream {
            switch signal {
            case .launch:
                guard !launched else { continue }
                launched = true
                await launch(env)
                if env.startsActive {
                    phase = .active
                    env.onEvent("cz_app_opened", [:])
                }
            case .active:
                guard launched else { continue }
                // Karar: yalnız ön plana GERÇEK geçiş `opened` sayılır. `didBecomeActive` kontrol/bildirim
                // merkezi kapanışında ve uygulama değiştiricisinden dönüşte de gelir; bunlar arka plan
                // görmediği için oturum/DAU şişirirdi. Durum yalnız `background` sinyaliyle `opened`'a
                // izin verir ve her `active` onu tüketir, yani takılıp sonraki gerçek açılışı yutamaz.
                // Başlangıç `unknown`: ilk `active` her zaman sayılır.
                guard phase != .active else { continue }
                phase = .active
                env.onEvent("cz_app_opened", [:])
            case .background:
                guard launched else { continue }
                phase = .background
                env.onEvent("cz_app_backgrounded", [:])
                // Event'ten sonra: flush onu da kuyruktan götürsün.
                env.onBackground()
            }
        }
    }

    /// Kurulum/güncelleme kararı. Önce durum yazılır, sonra event üretilir: yazma başarısızsa bile event
    /// üretilir ama süreç belleğine işlenir (tekrarı engeller); kurulum sayısı hiçbir yolda şişmez.
    private static func launch(_ env: Environment) async {
        let current = LifecycleSnapshot(version: env.app.version, build: env.app.build)
        let key = env.store.key
        let remembered = await UnpersistedLifecycle.shared.get(key)
        let stored = remembered.map { LifecycleStateStore.Loaded.value($0) } ?? env.store.load()

        switch stored {
        case .unreadable:
            // Okunamayan kayıt hakkında karar verilmez ve üzerine yazılmaz; eksik sayım şişirmeden iyidir.
            return
        case .corrupt:
            // Kayıt vardı, yani ilk açılış değil; sürüm bilinmediğinden `updated` da üretilmez. Yenilenir.
            await record(current, env, key)
        case .absent:
            // Sürüm okunamasa da `installed` üretilir (kurulum metriği sürüme bağlı olmamalı); durum
            // boş sürümle yine yazılır ki sonraki açılış tekrar "ilk" sanmasın.
            await record(current, env, key)
            env.onEvent("cz_app_installed", ["existing_install": env.existingInstall])
        case .value(let previous):
            // Sürüm okunamıyorsa karşılaştırılamaz: kayıt bozulmadan bırakılır (bilinen sürüm silinmez).
            guard let version = current.version else { return }
            guard let previousVersion = previous.version else {
                // Önceki sürüm bilinmiyordu: bildirilecek bir `previous_version` yok, yalnız kaydedilir.
                await record(current, env, key)
                return
            }
            guard previousVersion != version || previous.build != current.build else { return }
            await record(current, env, key)
            // Karar: `updated` "sürüm değişti" demektir, yön değil; düşürme (downgrade) de sayılır.
            // Android ile aynı (parity); yön ayrımı gerekirse sunucu iki sürümü karşılaştırabilir.
            var props: [String: Any] = ["previous_version": previousVersion]
            if let b = previous.build { props["previous_build"] = b }
            env.onEvent("cz_app_updated", props)
        }
    }

    private static func record(_ snapshot: LifecycleSnapshot, _ env: Environment, _ key: String) async {
        let saved = env.store.save(snapshot)
        await UnpersistedLifecycle.shared.set(key, saved ? nil : snapshot)
    }
}

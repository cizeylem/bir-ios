import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Çizeylem SDK'sının **tek** kamuya açık yüzeyi.
///
/// Tasarım kuralları:
/// - `initialize` dışındaki hiçbir çağrı `await` istemez ve hiçbiri çağıranı bloklamaz:
///   her çağrı tek bir sıraya (`CommandPipe`) girer, iş `actor Core`'da yapılır.
/// - `initialize` çağrılmadan yapılan çağrılar **sessizce yok sayılır**; çökme yok.
/// - Üç rıza anahtarı da **varsayılan kapalıdır**: `setConsent` çağrılmadan ne kalıcı kimlik
///   yazılır ne de event gönderilir.
public enum Cizeylem {
    /// SDK sürümü (`context.lib_version`). Tek kaynak: depo kökündeki `VERSION` dosyası;
    /// `CizeylemTests.testLibVersionSurumKaynagiylaAyni` ikisinin ayrışmasını engeller.
    public static let version = "0.1.0"

    private static let pipe = CommandPipe()

    /// SDK'yı kurar. **Ana thread'den çağrılır** (`@MainActor`): IDFV, ekran boyutu ve
    /// uygulama durumu UIKit'e bağlıdır ve yalnız ana aktörde okunabilir. Burada bir kez
    /// okunup düz değer olarak çekirdeğe geçerler; arka plandan ana thread'e **senkron
    /// sıçrama yoktur** (sıçrama, ana thread actor'ü beklerken süreci kilitlerdi).
    ///
    /// Çağrı bloklamaz: okumalar bittiği an döner, kurulum arka planda sürer.
    /// İkinci çağrı yok sayılır.
    @MainActor
    public static func initialize(_ config: Configuration) {
        var deps = Core.Dependencies()
        deps.vendorHash = VendorId.currentHash()
        deps.device = DeviceSnapshot.capture()
        deps.app = .main
        deps.installSource = InstallSource.current
        let monitor = NetworkMonitor()
        deps.network = { monitor.current }

        #if canImport(UIKit) && !os(watchOS)
        let state = UIApplication.shared.applicationState
        // İki ayrı soru, iki ayrı cevap:
        // - `startsActive`: ilk `cz_app_opened`'ı SDK kurulmadan önce kaçırdık mı? `didFinishLaunching`
        //   sırasında durum `.inactive`'dir, yani burada `false` çıkar ve hemen ardından gelen
        //   gerçek `didBecomeActive` bildirimi `opened`'ı üretir — çift event olmaz.
        // - `appState`: context alanı. `.inactive` ön plandır (açılış animasyonu, çağrı bandı),
        //   arka plan değildir.
        deps.startsActive = state == .active
        deps.appState = state == .background ? "background" : "foreground"
        #elseif canImport(AppKit)
        deps.startsActive = NSApplication.shared.isActive
        deps.appState = NSApplication.shared.isActive ? "foreground" : "background"
        #endif

        pipe.send(.start(config, deps))
    }

    // MARK: - Event'ler

    /// Event kuyruğa alır. Rıza yoksa hiçbir şey yapmaz.
    ///
    /// `$` önekli prop anahtarları atılır: sunucu böyle bir anahtar gören event'in **tamamını**
    /// düşürür.
    public static func track(_ name: String, _ props: [String: Any]? = nil) {
        pipe.send(.track(name, PropValue.props(props)))
    }

    /// Anonim kimliği `userId`'ye bağlar. `$identify` eski anonim `distinct_id` ile gider,
    /// sonraki event'ler `user_id` ile. `user_id` kalıcı yazılır.
    public static func identify(_ userId: String, _ props: [String: Any]? = nil) {
        pipe.send(.identify(userId, PropValue.props(props)))
    }

    /// Bir sonraki event'e iliştirilecek `$set` property'leri biriktirir.
    public static func setUserProperties(_ props: [String: Any]) {
        pipe.send(.setUserProperties(PropValue.map(props)))
    }

    /// Yalnız ilk kez yazılacak property'leri biriktirir (`$set_once`).
    public static func setUserPropertiesOnce(_ props: [String: Any]) {
        pipe.send(.setUserPropertiesOnce(PropValue.map(props)))
    }

    /// Sayısal property artışlarını biriktirir (`$add`). Aynı anahtar birden çok çağrıda toplanır.
    public static func addUserProperties(_ props: [String: Double]) {
        pipe.send(.addUserProperties(props))
    }

    /// Silinecek user property anahtarlarını biriktirir (`$unset`).
    public static func unsetUserProperties(_ keys: [String]) {
        pipe.send(.unsetUserProperties(keys))
    }

    /// Biriken property operasyonlarını bir sonraki event'i beklemeden `$identify` olarak gönderir.
    /// Anonim kullanıcıda da çalışır.
    public static func sendUserProperties(userId: String? = nil) {
        pipe.send(.sendUserProperties(userId))
    }

    /// Deep link'ten `cz_deep_link_opened` üretir. Yalnız `utm_*`, `click_id` ve `campaign_ids`
    /// okunur; tam URL ve beyaz liste dışı parametreler **gönderilmez**.
    public static func handleDeepLink(_ url: URL) {
        pipe.send(.deepLink(url))
    }

    // MARK: - Rıza

    /// Kullanıcı rızasını kalıcı olarak yazar.
    ///
    /// Rıza geri alınınca (üçü de kapalı) kuyruk, `device_id`, oturum, `user_id` ve yaşam
    /// döngüsü durumu **silinir** ve gözlemci bırakılır. Silme yalnız bu **açık** çağrıyla olur:
    /// diskten okunamayan rıza "geri alındı" sayılmaz.
    public static func setConsent(_ consent: Consent) {
        pipe.send(.setConsent(consent))
    }

    /// Geriye uyumluluk. `true` üç anahtarı da kapatır; `false` **yalnız** `analytics`'i açar
    /// (`attribution`/`adSharing` varsayılmaz — onlar için `setConsent` kullanın).
    public static func setOptOut(_ optOut: Bool) {
        pipe.send(.setOptOut(optOut))
    }

    // MARK: - Attribution

    /// `CizeylemAttribution` modülünün çıktısını çekirdeğe taşır. `initialize` çağrılmadan
    /// kullanılırsa sinyal sessizce düşer.
    public static var attributionSink: AttributionSink {
        let pipe = pipe
        return CoreAttributionSink { route, fields in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pipe.send(.query { core in
                    await core?.sendAttribution(route, fields)
                    continuation.resume()
                })
            }
        }
    }

    // MARK: - Kontrol

    /// Kuyruğu sunucuya gönderir (en-iyi-çaba, beklenmez).
    public static func flush() {
        pipe.send(.flush)
    }

    /// Çıkışta yeni anonim kimlik üretir. Sunucuya çağrı yapılmaz.
    public static func reset() {
        pipe.send(.reset)
    }

    /// Geçerli `distinct_id` (`user_id` varsa o, yoksa `device_id`). Rıza yoksa `nil`.
    public static func distinctId() async -> String? {
        await withCheckedContinuation { continuation in
            pipe.send(.query { core in
                continuation.resume(returning: await core?.distinctId())
            })
        }
    }

    /// SDK'nın kendi sağlığı. Hiçbir alanı sunucuya gitmez.
    public static func stats() async -> Stats {
        await withCheckedContinuation { continuation in
            pipe.send(.query { core in
                continuation.resume(returning: await core?.stats() ?? .idle)
            })
        }
    }
}

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Ana thread'e bağlı değerler. UIKit/AppKit bunları yalnız ana aktörde okutur; bu yüzden kurulum
/// anında bir kez okunup düz değer olarak taşınır ve `get()` hiçbir UI API'sine dokunmaz.
struct DeviceSnapshot: Sendable, Equatable {
    var isPad: Bool
    var screenWidth: Double?
    var screenHeight: Double?

    @MainActor
    static func capture() -> DeviceSnapshot {
        #if canImport(UIKit)
        // `fixedCoordinateSpace` cihazın doğal yönündeki pt boyutudur; yön değişiminden etkilenmez.
        let bounds = UIScreen.main.fixedCoordinateSpace.bounds
        return DeviceSnapshot(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            screenWidth: Double(bounds.width), screenHeight: Double(bounds.height))
        #elseif canImport(AppKit)
        let frame = NSScreen.main?.frame
        return DeviceSnapshot(
            isPad: false, screenWidth: frame.map { Double($0.width) }, screenHeight: frame.map { Double($0.height) })
        #else
        return DeviceSnapshot(isPad: false, screenWidth: nil, screenHeight: nil)
        #endif
    }
}

/// `Info.plist` değerleri. Süreç boyunca değişmez.
struct AppInfo: Sendable, Equatable {
    var version: String?
    var build: String?

    static var main: AppInfo {
        let info = Bundle.main.infoDictionary
        return AppInfo(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String)
    }
}

enum InstallSource {
    /// Makbuz adından kurulum kaynağı. Bilinmiyorsa `nil`: alan yazılmaz. `marketplace` için türetme
    /// kuralı yok, o yüzden hiç üretilmez.
    ///
    /// `AppTransaction` kullanılmaz: ağ maliyeti ve Privacy Manifest yükü getirir.
    static func derive(receiptName: String?, receiptExists: Bool, isSimulator: Bool) -> String? {
        if isSimulator { return "dev" }
        switch receiptName {
        case "sandboxReceipt": return "testflight"
        // Geliştirme derlemelerinde de aynı ad döner ama dosya yoktur; dosya yoksa App Store demeyiz.
        case "receipt" where receiptExists: return "app_store"
        default: return nil
        }
    }

    static var current: String? {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let url = Bundle.main.appStoreReceiptURL
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return derive(receiptName: url?.lastPathComponent, receiptExists: exists, isSimulator: simulator)
    }
}

/// Son bilinen ağ durumu. İzleyici bir kez kurulur; `current` ağ sorgusu yapmaz, beklemez.
///
/// Durum `NWPathMonitor.currentPath`'tedir (iş parçacığı güvenli). İlk güncelleme gelene kadar durum
/// bilinmez ve `nil` döner, alan yazılmaz: bilmemek ne çevrimdışı olmaktır ne de `other`.
///
/// "İlk güncelleme geldi" bilgisi 0'dan başlayan bir semafordur, yani fiilen bir bayrak: işleyici her
/// güncellemede `signal()` eder, `isKnown` bir `wait` + geri `signal` ile bakar. libdispatch semaforu
/// yalnız değeri başlangıçtan küçükken serbest bırakılırsa çöker; 0'dan başlayınca değer hiçbir zaman
/// 0'ın altında kalmaz, bu yüzden `deinit`te denge kurmaya, çift ya da gecikmiş işleyici çağrısından
/// korkmaya gerek yok. Bedeli: iki thread aynı anda `isKnown` okursa biri anlık `false` görebilir; sonuç
/// yalnız bir event'te eksik `network_type`'tır, yanlış değer değil.
final class NetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()
    private let updated = DispatchSemaphore(value: 0)

    init(autostart: Bool = true) {
        guard autostart else { return }
        let updated = updated
        monitor.pathUpdateHandler = { _ in updated.signal() }
        monitor.start(queue: DispatchQueue(label: "co.cizeylem.network", qos: .utility))
    }

    deinit { monitor.cancel() }

    var isKnown: Bool {
        guard updated.wait(timeout: .now()) == .success else { return false }
        updated.signal()
        return true
    }

    var current: String? {
        guard isKnown else { return nil }
        let path = monitor.currentPath
        return Self.classify(
            satisfied: path.status == .satisfied,
            wifi: path.usesInterfaceType(.wifi),
            cellular: path.usesInterfaceType(.cellular),
            wired: path.usesInterfaceType(.wiredEthernet))
    }

    static func classify(satisfied: Bool, wifi: Bool, cellular: Bool, wired: Bool) -> String {
        guard satisfied else { return "offline" }
        if wifi { return "wifi" }
        if cellular { return "cellular" }
        if wired { return "ethernet" }
        return "other"
    }
}

/// Her event'e eklenen context (SPEC §4).
///
/// `get()` saftır: UI API'sine, ağa ya da diske dokunmaz ve her thread'den çağrılabilir. Ana thread'e
/// bağlı değerler kurulumda (`@MainActor init`) bir kez yakalanır. Süreç ömründe sabit alanlar
/// (sürüm, build, kurulum kaynağı, model) kurulumda; değişebilenler (ağ, durum, locale, saat dilimi,
/// rıza) her çağrıda hesaplanır.
struct ContextProvider: Sendable {
    private let libVersion: String
    private let platform: String
    private let device: DeviceSnapshot
    private let app: AppInfo
    private let installSource: String?
    private let deviceModel: String
    private let network: @Sendable () -> String?

    init(
        libVersion: String, platform: Platform, device: DeviceSnapshot, app: AppInfo,
        installSource: String?, deviceModel: String = DeviceModel.identifier,
        network: @escaping @Sendable () -> String?
    ) {
        self.libVersion = libVersion
        self.platform = platform.name
        self.device = device
        self.app = app
        self.installSource = installSource
        self.deviceModel = deviceModel
        self.network = network
    }

    /// Üretim kurulumu: ana aktörde bir kez çağrılır.
    @MainActor
    init(libVersion: String, platform: Platform) {
        let monitor = NetworkMonitor()
        self.init(
            libVersion: libVersion, platform: platform, device: DeviceSnapshot.capture(),
            app: AppInfo.main, installSource: InstallSource.current,
            network: { monitor.current })
    }

    func get(consent: Consent, appState: String, attStatus: String?) -> [String: Any] {
        var m: [String: Any] = [
            "lib": "bir-ios",
            "lib_version": libVersion,
            "platform": platform,
            "os_name": osName,
            "os_version": Self.osVersion,
            "device_model": deviceModel,
            "device_type": deviceType,
            "device_manufacturer": "Apple",
            "locale": Self.locale,
            "timezone": TimeZone.autoupdatingCurrent.identifier,
            "app_state": appState,
        ]
        if let n = network() { m["network_type"] = n }
        if let v = app.version { m["app_version"] = v }
        if let b = app.build { m["app_build"] = b }
        if let s = installSource { m["install_source"] = s }
        if let w = device.screenWidth, let h = device.screenHeight {
            let (nw, nh) = Self.natural(width: w, height: h, landscape: platform != "ios")
            m["screen_width"] = nw
            m["screen_height"] = nh
        }
        if let a = attStatus { m["att_status"] = a }
        if let scope = Self.consentScope(consent) { m["consent_scope"] = scope }
        return m
    }

    private var osName: String {
        switch platform {
        case "tvos": return "tvOS"
        case "macos": return "macOS"
        default: return device.isPad ? "iPadOS" : "iOS"
        }
    }

    private var deviceType: String {
        switch platform {
        case "tvos": return "tv"
        case "macos": return "desktop"
        default: return device.isPad ? "tablet" : "mobile"
        }
    }

    /// Doğal yöne normalize: telefon/tablet dikey, TV ve Mac yatay. Yön değişimi değeri oynatmaz.
    static func natural(width: Double, height: Double, landscape: Bool) -> (Double, Double) {
        let long = max(width, height), short = min(width, height)
        return landscape ? (long, short) : (short, long)
    }

    /// `ProcessInfo` her thread'den okunur; `UIDevice.systemVersion` ana aktöre bağlıdır.
    private static var osVersion: String { formatOSVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    static func formatOSVersion(_ v: OperatingSystemVersion) -> String {
        v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// BCP 47 (`tr-TR`); `identifier`daki `_` ve `@calendar=...` eki sunucuya gitmez.
    private static var locale: String { bcp47(Locale.autoupdatingCurrent.identifier) }

    static func bcp47(_ id: String) -> String {
        let base = id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? id
        return base.replacingOccurrences(of: "_", with: "-")
    }

    /// Yalnız verilen anahtarlar, virgülle (Android ile aynı biçim). Hiçbiri yoksa `nil`.
    private static func consentScope(_ c: Consent) -> String? {
        var keys: [String] = []
        if c.analytics { keys.append("analytics") }
        if c.attribution { keys.append("attribution") }
        if c.adSharing { keys.append("adSharing") }
        return keys.isEmpty ? nil : keys.joined(separator: ",")
    }
}

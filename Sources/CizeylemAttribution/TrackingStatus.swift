import Foundation
#if os(iOS) && canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if os(iOS) && canImport(AdSupport)
import AdSupport
#endif

/// ATT durumu ve IDFA. Durum yalnız **okunur**: izin penceresini açmak uygulamanın işidir
/// ve uygulama-içi rıza ekranından SONRA gelir (SPEC §5). ATT hukuki rıza değildir.
enum TrackingStatus {
    static func current() -> String {
        #if os(iOS) && canImport(AppTrackingTransparency)
        return name(forRawValue: ATTrackingManager.trackingAuthorizationStatus.rawValue)
        #else
        // tvOS ve macOS: SDK durumu okumaz.
        return "unavailable"
        #endif
    }

    /// `ATTrackingManager.AuthorizationStatus` ham değerlerinin tel adı. Bilinmeyen değer
    /// (Apple yeni durum eklerse) `unavailable`: "authorized" asla tahminle üretilmez.
    static func name(forRawValue raw: UInt) -> String {
        switch raw {
        case 0: return "not_determined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"
        default: return "unavailable"
        }
    }

    /// Reklam kimliği. Çağıran ATT `authorized` ve rıza kapılarını GEÇMİŞSE çağırır.
    static func idfa() -> String? {
        #if os(iOS) && canImport(AdSupport)
        return ASIdentifierManager.shared().advertisingIdentifier.uuidString
        #else
        return nil
        #endif
    }
}

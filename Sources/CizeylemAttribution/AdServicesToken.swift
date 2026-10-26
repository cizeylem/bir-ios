import Foundation
#if !os(tvOS) && canImport(AdServices)
import AdServices
#endif

/// AdServices attribution token'ı. Sunucu çözer; SDK içeriğine bakmaz.
///
/// tvOS'ta AdServices yoktur: orada her zaman `nil`.
enum AdServicesToken {
    static func read() -> String? {
        #if !os(tvOS) && canImport(AdServices)
        // Simülatörde ve Apple Search Ads dışı kurulumlarda fırlatır; bu normaldir, sinyal yoktur.
        return normalize(try? AAAttribution.attributionToken())
        #else
        return nil
        #endif
    }

    /// Boş token sinyal değildir; sunucuya boş alan gitmesin.
    static func normalize(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token
    }
}

import Foundation
#if !os(tvOS) && canImport(AdServices)
import AdServices
#endif

/// Token okumasının sonucu. Geçici hata "token yok"tan ayrılır: ağ hatasında sinyal token'sız
/// gönderilirse kurulumun reklam bağlantısı kalıcı olarak kaybolur.
enum TokenRead: Sendable, Equatable {
    case token(String)
    /// Bu platformda token yok (`platformNotSupported`, tvOS) ya da boş geldi: sinyal token'sız gider.
    case unavailable
    /// `networkError` / `internalError` / bilinmeyen hata: deneme sayılır, sonra yeniden.
    case transient
}

/// AdServices attribution token'ı. Sunucu çözer (cizeylem-1 `PROTOCOL.md` §9.1); SDK içeriğine bakmaz.
///
/// Apple'a göre token üretimi yalnız `networkError`, `internalError` ve `platformNotSupported` ile
/// düşer; Apple Ads dışı kurulumlar da token üretir (sunucu "eşleşme yok" alır). Token 24 saat
/// yaşar: diske yazılmaz, her denemede taze üretilir.
///
/// tvOS'ta AdServices yoktur: orada her zaman `.unavailable`.
enum AdServicesToken {
    static func read() -> TokenRead {
        #if !os(tvOS) && canImport(AdServices)
        do {
            return normalize(try AAAttribution.attributionToken()).map(TokenRead.token) ?? .unavailable
        } catch let error as AAAttributionError {
            return error.code == .platformNotSupported ? .unavailable : .transient
        } catch {
            return .transient
        }
        #else
        return .unavailable
        #endif
    }

    /// Boş token sinyal değildir; sunucuya boş alan gitmesin.
    static func normalize(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token
    }
}

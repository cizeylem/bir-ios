import Foundation
import Cizeylem
#if os(iOS) && canImport(StoreKit)
import StoreKit
#endif
#if os(iOS) && canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// SKAN / AdAttributionKit dönüşüm değeri yazıcısı. **Varsayılan kapalıdır**: yalnız host
/// `Attribution.enableConversionWriter` çağırırsa çalışır.
///
/// Paralel testte değeri AppsFlyer yazar; iki yazıcı aynı pencereye yazarsa postback geri
/// alınamaz biçimde bozulur. Bu yüzden her belirsizlikte (şema yok/bozuk, rıza yok, platform
/// yok) sonuç "hiçbir şey yazma"dır; yedek şema ya da gömülü varsayılan **yoktur**.
enum ConversionWriter {
    enum Outcome: Sendable, Equatable {
        case unsupportedPlatform, noConsent, noSchema, noMatchingRule, wrote
    }

    /// Dış dünya: şema indirme ve sistem yüzeyi. Üretimde gerçek, testte sayaçlı sahte.
    struct Environment: Sendable {
        var fetch: @Sendable (URL) async -> Data?
        var surface: @Sendable (_ fine: Int, _ coarse: String, _ lock: Bool) async -> Void
        var supported: Bool

        init(fetch: @escaping @Sendable (URL) async -> Data?,
             surface: @escaping @Sendable (Int, String, Bool) async -> Void,
             supported: Bool = ConversionWriter.platformSupported) {
            self.fetch = fetch
            self.surface = surface
            self.supported = supported
        }

        static let live = Environment(fetch: { await ConversionWriter.download($0) },
                                      surface: { await ConversionWriter.systemWrite($0, $1, $2) })
    }

    /// SKAdNetwork ve AdAttributionKit yalnız iOS'ta vardır (SPEC §8). tvOS'ta (ve paket testinin
    /// koştuğu macOS'ta) derleme zamanında kapalıdır; çağrılsa bile hiçbir şey yapılmaz.
    static var platformSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Saf: ağ, disk ya da sistem API'si yok. Eşiği geçen kurallar arasında en yüksek `fine`
    /// kazanır (SKAN değeri yalnız yükselebilir); eşitlikte şemadaki ilk kural.
    /// Şema geçersizse (ör. decode'u atlayan elle kurulmuş) hiçbir şey döndürmez.
    static func apply(_ schema: ConversionSchema, events: [String: Int])
        -> (fine: Int, coarse: String, lock: Bool)? {
        guard schema.isValid else { return nil }
        var best: ConversionSchema.Rule?
        for rule in schema.rules where (events[rule.event] ?? 0) >= rule.min {
            if best == nil || rule.fine > best!.fine { best = rule }
        }
        guard let best else { return nil }
        return (best.fine, best.coarse, best.lockWindow)
    }

    /// Kapı sırası ucuzdan pahalıya: platform, rıza, ağ, şema, kural, yazma. Her kapı kapanınca
    /// sonrası (özellikle ağ) hiç çalışmaz.
    static func run(schemaURL: URL, consent: Consent, events: [String: Int],
                    environment: Environment) async -> Outcome {
        guard environment.supported else { return .unsupportedPlatform }
        guard consent.allowsConversionWrite else { return .noConsent }
        // http şema bir ortadaki adamın değer yazdırmasına açıktır.
        guard schemaURL.scheme?.lowercased() == "https",
              let data = await environment.fetch(schemaURL),
              let schema = ConversionSchema.decode(data) else { return .noSchema }
        guard let value = apply(schema, events: events) else { return .noMatchingRule }
        await environment.surface(value.fine, value.coarse, value.lock)
        return .wrote
    }

    // MARK: Gerçek yüzeyler

    /// Şema küçük bir JSON'dur; büyük yanıt bozuk/saldırgan sayılır.
    private static let maxSchemaBytes = 64 * 1024

    static func download(_ url: URL) async -> Data? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= maxSchemaBytes else { return nil }
        return data
    }

    /// iOS 17.4+ AdAttributionKit, 16.1+ SKAdNetwork (fine+coarse+lock), 15.4+ yalnız fine.
    /// Yalnız biri çağrılır; ikisini birden yazmak çifte yazıcı olurdu. Hata yutulur: ev sahibi
    /// uygulama yazma hatasından etkilenmemeli ve yeniden denemek de yanlış pencereye yazabilir.
    static func systemWrite(_ fine: Int, _ coarse: String, _ lock: Bool) async {
        #if os(iOS) && canImport(AdAttributionKit)
        if #available(iOS 17.4, *), let value = AdAttributionKit.CoarseConversionValue(rawValue: coarse) {
            try? await AdAttributionKit.Postback.updateConversionValue(
                fine, coarseConversionValue: value, lockPostback: lock)
            return
        }
        #endif
        #if os(iOS) && canImport(StoreKit)
        if #available(iOS 16.1, *) {
            let value: SKAdNetwork.CoarseConversionValue
            switch coarse {
            case "high": value = .high
            case "medium": value = .medium
            default: value = .low
            }
            try? await SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: value, lockWindow: lock)
        } else if #available(iOS 15.4, *) {
            try? await SKAdNetwork.updatePostbackConversionValue(fine)
        }
        #endif
    }
}

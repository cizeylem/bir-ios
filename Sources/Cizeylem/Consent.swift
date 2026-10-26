/// Kullanıcı rızası: üç anahtar, hepsi varsayılan olarak kapalı.
///
/// Anahtarlar katmanlıdır (SPEC §5): `analytics` kalıcı kimliği ve event'leri açar,
/// `attribution` yalnız `analytics` ile birlikte `device_id`'li attribution'ı açar,
/// `adSharing` yalnız reklam kimliği/`att_status` kapısıdır ve tek başına hiçbir şeyi açmaz.
public struct Consent: Sendable, Equatable {
    public let analytics: Bool
    public let attribution: Bool
    public let adSharing: Bool

    public init(analytics: Bool = false, attribution: Bool = false, adSharing: Bool = false) {
        self.analytics = analytics
        self.attribution = attribution
        self.adSharing = adSharing
    }
}

/// Attribution sinyalinin gideceği uç. Kimliksiz uç (`/v1/attribution/anon`) sözleşmesi gereği
/// ne `device_id` ne de reklam kimliği taşır.
enum AttributionRoute: Sendable {
    case identified
    case anonymous
}

/// Tüm rıza kararları burada, tek yerde. Çağıranlar anahtarları kendi başlarına birleştirmez.
extension Consent {
    /// Kalıcı kimlik yazımı ve event kuyruğa alma. Tek anahtar `analytics`: `attribution`/`adSharing`
    /// onsuz hiçbir kalıcı iz açmaz.
    var allowsWrite: Bool { analytics }

    /// Sinyalin `device_id` ile gidebilmesi: kalıcı kimliği açan anahtar `analytics`'tir,
    /// `attribution` tek başına yetmez.
    var allowsIdentifiedAttribution: Bool { analytics && attribution }

    /// `att_status` alanı: reklam paylaşımı kimlikli yolun üstüne biner.
    var allowsAttStatus: Bool { allowsIdentifiedAttribution && adSharing }

    func allowsDeviceId(on route: AttributionRoute) -> Bool {
        switch route {
        case .identified: return allowsIdentifiedAttribution
        case .anonymous: return false
        }
    }

    /// IDFA (ve her reklam kimliği) yalnız kimlikli yolda toplanır ve gönderilir. Kimliksiz uçtaki
    /// kayıtlar bir reklam kimliğiyle yeniden kimliklendirilebilir; bu yüzden `adSharing` o uca
    /// hiçbir kombinasyonda IDFA açmaz.
    func allowsIdfa(on route: AttributionRoute) -> Bool {
        switch route {
        case .identified: return allowsAttStatus
        case .anonymous: return false
        }
    }
}

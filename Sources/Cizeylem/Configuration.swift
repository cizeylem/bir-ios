import Foundation

/// SDK yapılandırması. Değer tipi ve `Sendable`: kurulumdan sonra değişmez, actor sınırını
/// serbestçe geçer.
public struct Configuration: Sendable {
    /// Yazma anahtarı (`ck_w_…`). `Authorization: Bearer` başlığına girer.
    public let writeKey: String
    /// Toplama ucu. Yol (`/v1/batch`) `Transport` tarafından eklenir.
    public let endpoint: URL
    /// Dıştan dayatılan `device_id` (SPEC §6 devralma zincirinin ilk halkası). Boş/boşluk ise yok sayılır.
    public let deviceId: String?
    /// Kuyruk bu sayıya ulaşınca gönderim tetiklenir. Verilmezse `Platform.current.flushAt`
    /// (iOS/macOS 30, tvOS 5).
    public let flushAt: Int?
    /// Zamanlayıcı aralığı (sn). `0` ya da altı zamanlayıcıyı kapatır.
    public let flushInterval: TimeInterval
    /// Amplitude `device_id` devralmasını (salt okuma) aç/kapa.
    public let legacyAmplitude: Bool
    /// **Amplitude'un** API anahtarı; Çizeylem'in write key'i (`writeKey`) DEĞİLDİR.
    ///
    /// Amplitude-Swift, kimliğini adı bu anahtarı içeren bir `UserDefaults` suite'inde tutar
    /// (`com.amplitude.storage.amplitude-swift-storage-<anahtar>-<instance>`); devralma o suite'i
    /// ancak bu anahtarla bulabilir. Verilmezse (`nil` ya da boş) Amplitude-Swift suite'i HİÇ
    /// taranmaz; eski ObjC SQLite yolu anahtara ihtiyaç duymadığından yine denenir.
    /// `legacyAmplitude == false` ise bu alan da kullanılmaz.
    public let legacyAmplitudeApiKey: String?
    /// SDK uyarıları buraya gider. `nil` ise uyarı yutulur: bir SDK ev sahibinin konsolunu
    /// izinsiz kirletmez (`print` yok).
    ///
    /// Her thread'den ve actor'den çağrılabilir; bu yüzden `@Sendable`.
    public let logger: (@Sendable (String) -> Void)?

    public init(
        writeKey: String,
        endpoint: URL = Configuration.defaultEndpoint,
        deviceId: String? = nil,
        flushAt: Int? = nil,
        flushInterval: TimeInterval = 30,
        legacyAmplitude: Bool = true,
        legacyAmplitudeApiKey: String? = nil,
        logger: (@Sendable (String) -> Void)? = nil
    ) {
        self.writeKey = writeKey
        self.endpoint = endpoint
        self.deviceId = deviceId
        self.flushAt = flushAt
        self.flushInterval = flushInterval
        self.legacyAmplitude = legacyAmplitude
        self.legacyAmplitudeApiKey = legacyAmplitudeApiKey
        self.logger = logger
    }

    public static let defaultEndpoint = URL(string: "https://in.cizeylem.com")!
}

/// SDK'nın kendi sağlığı. Hata ayıklama ve ev sahibi uygulamanın tanılaması içindir;
/// hiçbir alanı sunucuya gitmez.
public struct Stats: Sendable, Equatable {
    /// Gönderilmeyi bekleyen event sayısı.
    public let queued: Int
    /// Kapasite sınırı yüzünden BİZİM attığımız event sayısı.
    public let dropped: Int
    /// Sunucunun kalıcı olarak reddettiği (400/413) event sayısı.
    public let rejected: Int
    /// Kendi yazdığımızı geri okuyamadığımız için silinen satır sayısı (Görev 9 tanılama kalemi).
    public let skipped: Int
    /// 401/403 sonrası SDK durdu mu.
    public let disabled: Bool
    /// `device_id` elde edilebiliyor mu. `false` ise SDK event yazamaz ama **sessizce ölmez**:
    /// durum buradan görünür ve her çağrıda yeniden denenir.
    public let deviceIdAvailable: Bool
    /// Bellekteki geçerli rıza.
    public let consent: Consent
    /// Kalıcı katman (kuyruk/gönderim/zamanlayıcı) kurulu mu. Rıza yoksa `false`.
    public let running: Bool

    static let idle = Stats(
        queued: 0, dropped: 0, rejected: 0, skipped: 0, disabled: false,
        deviceIdAvailable: true, consent: Consent(), running: false)
}

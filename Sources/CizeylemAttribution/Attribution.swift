import Foundation
import Cizeylem

/// Attribution sinyallerini toplayıp çekirdeğe (sink) bırakır.
///
/// Kapılar `Consent`'te tek yerdedir; burada birleştirilmez, çağrılır. Çekirdekteki
/// `AttributionBody` süzmesi bunlardan bağımsız ikinci katmandır.
public enum Attribution {
    /// Okuma kaynakları. Üretimde gerçek sistem çağrıları; testte sayaçlı sahteleri.
    struct Signals: Sendable {
        var token: @Sendable () -> String?
        var attStatus: @Sendable () -> String
        var idfa: @Sendable () -> String?

        static let live = Signals(
            token: { AdServicesToken.read() },
            attStatus: { TrackingStatus.current() },
            idfa: { TrackingStatus.idfa() })
    }

    /// Bir kez toplar ve gönderir; çağıranı bloklamaz (token okuma ağ yapabilir).
    /// `consent` o anki rızanın kopyasıdır; sonradan değişirse yeniden çağrılmalıdır.
    ///
    /// Dönüşüm değeri yazıcısını **kurmaz**: o ayrı ve açık bir çağrıdır
    /// (`enableConversionWriter`). Burada bir varsayılan yoktur, çünkü unutulan çağrı kapalı kalmalı.
    public static func start(sink: AttributionSink, consent: Consent) {
        _ = startTask(sink: sink, consent: consent, signals: .live, conversion: .live)
    }

    /// SKAN/AAK dönüşüm değeri yazıcısını açar. **Varsayılan kapalıdır** (K8): host uygulama paralel
    /// testte değeri AppsFlyer yazdırır ve iki yazıcı postback'i geri alınamaz biçimde bozar.
    /// Yalnız host bu işi üstlenecekse çağırmalıdır.
    ///
    /// - `schemaURL`: uzaktaki sürümlü JSON şema (https). Alınamaz ya da geçersizse hiçbir şey
    ///   yazılmaz; yedek şema yoktur.
    /// - `events`: şemadaki kurallara göre değerlendirilen event sayaçları.
    /// - tvOS'ta çağrı sessizce hiçbir şey yapmaz (SKAdNetwork/AAK yok).
    public static func enableConversionWriter(
        schemaURL: URL, events: [String: Int] = ["first_open": 1]
    ) {
        _ = enableConversionWriterTask(schemaURL: schemaURL, events: events, environment: .live)
    }

    /// Testin sonucu bekleyebilmesi için `Task` döndürür; `start` bunu çağırmaz.
    @discardableResult
    static func startTask(sink: AttributionSink, consent: Consent, signals: Signals,
                          conversion: ConversionWriter.Environment) -> Task<Void, Never> {
        // `conversion` bilerek kullanılmaz: start'ın yazıcıya dokunmadığı testle sabitlenir.
        _ = conversion
        return Task.detached(priority: .utility) {
            await run(sink: sink, consent: consent, signals: signals)
        }
    }

    @discardableResult
    static func enableConversionWriterTask(
        schemaURL: URL, events: [String: Int],
        environment: ConversionWriter.Environment
    ) -> Task<ConversionWriter.Outcome, Never> {
        Task.detached(priority: .utility) {
            await ConversionWriter.run(schemaURL: schemaURL, events: events, environment: environment)
        }
    }

    static func run(sink: AttributionSink, consent: Consent, signals: Signals) async {
        // Rıza yoksa bile token okunabilir: kimliksiz uç SPEC §5'te buna açıkça izin verir.
        var fields: [String: Any] = [:]
        if let token = AdServicesToken.normalize(signals.token()) { fields["adservices_token"] = token }

        let route: AttributionRoute = consent.allowsIdentifiedAttribution ? .identified : .anonymous

        // Her kapı kendi başına karar verir; biri ötekine yaslanmaz (biri bozulursa diğeri tutar).
        let wantsStatus = consent.allowsAttStatus
        let wantsIdfa = consent.allowsIdfa(on: route)

        // Durum rızasızken okunmaz bile; IDFA ayrıca ATT `authorized` ister (iki kapı).
        var status: String?
        if wantsStatus || wantsIdfa { status = signals.attStatus() }
        if wantsStatus, let status { fields["att_status"] = status }
        if wantsIdfa, status == "authorized", let idfa = usable(signals.idfa()) {
            fields["idfa"] = idfa
        }

        guard !fields.isEmpty else { return }
        switch route {
        case .identified: await sink.sendIdentified(fields)
        case .anonymous: await sink.sendAnonymous(fields)
        }
    }

    /// Sıfır reklam kimliği "izin yok"un sesidir (ATT kapalıyken sistem verir); kimlik değildir.
    private static func usable(_ idfa: String?) -> String? {
        guard let idfa else { return nil }
        let t = idfa.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = t.replacingOccurrences(of: "-", with: "")
        guard !digits.isEmpty, digits.contains(where: { $0 != "0" }) else { return nil }
        return t
    }
}

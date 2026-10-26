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
    public static func start(sink: AttributionSink, consent: Consent) {
        Task.detached(priority: .utility) {
            await run(sink: sink, consent: consent, signals: .live)
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
        let t = idfa.trimmingCharacters(in: .whitespaces)
        let digits = t.replacingOccurrences(of: "-", with: "")
        guard !digits.isEmpty, digits.contains(where: { $0 != "0" }) else { return nil }
        return t
    }
}

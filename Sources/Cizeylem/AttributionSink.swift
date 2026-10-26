import Foundation

/// `CizeylemAttribution` ile çekirdek arasındaki tek köprü. Attribution modülü ağa ya da
/// kimliğe dokunmaz; sinyali buraya bırakır, kimliği ve taşımayı çekirdek yönetir.
///
/// `sendIdentified`: `device_id` çekirdek tarafından, yalnız çekirdeğin kendi rızası varsa eklenir.
/// `sendAnonymous`: gövde ne verilirse verilsin kimliksiz çıkar (bkz. `AttributionBody`).
public protocol AttributionSink: Sendable {
    func sendIdentified(_ fields: [String: Any]) async
    func sendAnonymous(_ fields: [String: Any]) async
}

/// Attribution uçlarına tek POST atan taşıma (`Transport` uygular, testte sahtesi konur).
protocol AttributionSending: Sendable {
    func post(path: String, body: String) async -> (Outcome, retryAfter: Double?)
}

extension Transport: AttributionSending {}

/// Attribution gövdesinin TEK yazarı ve son kapı.
///
/// Neden ayrı bir süzme var: kapılar (`Consent.allowsIdfa(on:)`) çağıranın dikkatine bağlıdır.
/// Android'de reklam kimliği, sözleşmesi "kimlik yok" olan kimliksiz uca tam böyle sızdı ve tek
/// katman yetmedi. Burada çağıran ne verirse versin kimliksiz gövdeden bu anahtarlar atılır;
/// kapı ve süzme birbirinden bağımsız iki katmandır.
enum AttributionBody {
    /// Kimliksiz uç sözleşmesi: bunlardan hiçbiri gövdede olamaz.
    static let identityKeys: Set<String> = ["idfa", "device_id", "user_id", "distinct_id"]

    static func anonymous(_ fields: [String: Any]) -> String {
        encode(strip(fields))
    }

    /// Kimlikli gövde: `device_id` her zaman çekirdeğin verdiği değerdir (çağıranınki ezilir).
    static func identified(_ fields: [String: Any], deviceId: String) -> String {
        var o = fields
        o["device_id"] = deviceId
        return encode(o)
    }

    /// Büyük/küçük harf ve iç içe nesne fark etmez: sözleşme anahtarın yerini değil varlığını yasaklar.
    private static func strip(_ value: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in value where !identityKeys.contains(k.lowercased()) {
            if let nested = v as? [String: Any] { out[k] = strip(nested) } else { out[k] = v }
        }
        return out
    }

    /// Geçersiz JSON boş döner; çağıran göndermez (yarım gövde sunucuyu zehirlemesin).
    private static func encode(_ o: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let data = try? JSONSerialization.data(withJSONObject: o) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Çekirdeğe bağlanan sink. `deliver` üretimde komut hattına, testte doğrudan `Core`'a gider.
struct CoreAttributionSink: AttributionSink {
    let deliver: @Sendable (AttributionRoute, [String: PropValue]) async -> Void

    // `Any` actor sınırını geçemez: alanlar çağıranın thread'inde düz değere çevrilir.
    func sendIdentified(_ fields: [String: Any]) async {
        await deliver(.identified, PropValue.map(fields))
    }

    func sendAnonymous(_ fields: [String: Any]) async {
        await deliver(.anonymous, PropValue.map(fields))
    }
}

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
        encode(remove(identityKeys, from: fields))
    }

    /// Kimlikli gövde: `device_id` her zaman çekirdeğin verdiği değerdir (çağıranınki ezilir).
    /// `idfa`/`att_status` yalnız çekirdeğin KENDİ rızası izin veriyorsa kalır: çağıranın elindeki
    /// rıza kopyası eski olabilir (rıza geri alınmış), kimlikli uçta da tek katmana güvenilmez.
    static func identified(
        _ fields: [String: Any], deviceId: String, allowIdfa: Bool = false, allowAttStatus: Bool = false
    ) -> String {
        var drop: Set<String> = []
        if !allowIdfa { drop.insert("idfa") }
        if !allowAttStatus { drop.insert("attstatus") }
        var o = remove(drop, from: fields)
        o["device_id"] = deviceId
        return encode(o)
    }

    /// Anahtar karşılaştırması yazım varyantlarına dayanır (`deviceId`, `device-id`, `Device Id`):
    /// son kapı çağıranın hatasına karşıdır, tam eşleşme bunu yapmaz.
    static func normalize(_ key: String) -> String {
        String(key.lowercased().filter { $0 != "_" && $0 != "-" && !$0.isWhitespace })
    }

    private static let normalizedIdentityKeys: Set<String> = Set(identityKeys.map(normalize))

    private static func remove(_ keys: Set<String>, from value: [String: Any]) -> [String: Any] {
        let normalized = keys == identityKeys ? normalizedIdentityKeys : Set(keys.map(normalize))
        return strip(value, normalized)
    }

    /// Sözlük ve dizi içinde, istenen derinlikte özyineler: sözleşme anahtarın yerini değil varlığını yasaklar.
    private static func strip(_ value: [String: Any], _ keys: Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in value where !keys.contains(normalize(k)) { out[k] = clean(v, keys) }
        return out
    }

    private static func clean(_ v: Any, _ keys: Set<String>) -> Any {
        if let d = v as? [String: Any] { return strip(d, keys) }
        if let a = v as? [Any] { return a.map { clean($0, keys) } }
        return v
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

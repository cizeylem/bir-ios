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

/// Tek attribution isteğinin sonucu (çekirdekteki `Outcome`'un attribution'a dönük özeti).
package enum AttributionDelivery: Sendable, Equatable {
    /// Sunucu kabul etti (`2xx`): sinyal bitti.
    case sent
    /// Gövde kalıcı reddedildi (`400`) ya da kurulamadı: tekrar denemek düzeltmez.
    case rejected
    /// Geçici (ağ, `5xx`, `429`, kimlikli uçta henüz `device_id` yok): sonra tekrar.
    case retryLater
    /// Yazma anahtarı reddedildi (`401`/`403`) ya da SDK kurulmadı: bu süreçte bir daha denenmez.
    case stopped
}

/// Tekrar denemeye hazır zarf (cizeylem-1 `PROTOCOL.md` §9): `insert_id` tekrarlarda sabit,
/// `time` sinyalin ilk üretildiği an. `sent_at`'i çekirdek isteğin anında ekler.
package struct AttributionEnvelope: Sendable, Equatable {
    package let insertId: String
    package let timeMs: Int64?

    package init(insertId: String, timeMs: Int64?) {
        self.insertId = insertId
        self.timeMs = timeMs
    }
}

/// Kalıcı durum ve sonuç bildiren sink (SPEC §8.2). Yalnız çekirdeğin kendi sink'i uygular;
/// `AttributionSink`'i kendisi uygulayan bir host'ta `CizeylemAttribution` 0.3.0 gibi tek seferlik
/// gönderime düşer. Paket içi: kamuya açık yüzey büyümez.
package protocol AttributionStateSink: AttributionSink {
    func loadAttributionState() async -> AttributionStateLoad
    @discardableResult func saveAttributionState(_ state: AttributionState) async -> Bool
    func deliver(_ route: AttributionRoute, _ fields: [String: Any], envelope: AttributionEnvelope) async
        -> AttributionDelivery
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

    /// Gövde, herhangi bir derinlikte IDFA anahtarı taşıyor mu. İzleme ucu seçimi buna bağlıdır
    /// (`Configuration.trackingEndpoint`); bozuk gövde `false` döner ama zaten gönderilmez.
    static func carriesIdfa(_ body: String) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return false }
        return contains(normalize("idfa"), in: o)
    }

    private static func contains(_ key: String, in value: Any) -> Bool {
        if let d = value as? [String: Any] {
            return d.contains { normalize($0.key) == key || contains(key, in: $0.value) }
        }
        if let a = value as? [Any] { return a.contains { contains(key, in: $0) } }
        return false
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

/// Çekirdeğe bağlanan sink. Kapanımlar üretimde komut hattına, testte doğrudan `Core`'a gider.
package struct CoreAttributionSink: AttributionStateSink {
    let send: @Sendable (AttributionRoute, [String: PropValue], AttributionEnvelope?) async -> AttributionDelivery
    let load: @Sendable () async -> AttributionStateLoad
    let save: @Sendable (AttributionState) async -> Bool

    init(
        send: @escaping @Sendable (AttributionRoute, [String: PropValue], AttributionEnvelope?) async -> AttributionDelivery,
        load: @escaping @Sendable () async -> AttributionStateLoad = { .unavailable },
        save: @escaping @Sendable (AttributionState) async -> Bool = { _ in false }
    ) {
        self.send = send
        self.load = load
        self.save = save
    }

    /// Testlerin `Core`'a doğrudan bağlanan sink'i.
    init(core: Core) {
        self.init(
            send: { route, fields, envelope in await core.sendAttribution(route, fields, envelope: envelope) },
            load: { await core.loadAttributionState() },
            save: { await core.saveAttributionState($0) })
    }

    // `Any` actor sınırını geçemez: alanlar çağıranın thread'inde düz değere çevrilir.
    package func sendIdentified(_ fields: [String: Any]) async {
        _ = await send(.identified, PropValue.map(fields), nil)
    }

    package func sendAnonymous(_ fields: [String: Any]) async {
        _ = await send(.anonymous, PropValue.map(fields), nil)
    }

    package func loadAttributionState() async -> AttributionStateLoad { await load() }

    @discardableResult
    package func saveAttributionState(_ state: AttributionState) async -> Bool { await save(state) }

    package func deliver(_ route: AttributionRoute, _ fields: [String: Any], envelope: AttributionEnvelope) async
        -> AttributionDelivery {
        await send(route, PropValue.map(fields), envelope)
    }
}

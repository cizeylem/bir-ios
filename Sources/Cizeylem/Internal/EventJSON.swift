import Foundation

/// Kullanıcı özelliği operasyonları (`$set`, `$set_once`, `$unset`, `$add`). Hepsi opsiyonel;
/// `nil` ya da boş olan gövdeye yazılmaz.
///
/// `Sendable` değil: değerler `Any` taşır (props dinamiktir) ve derleyici bunu `Sendable` kabul etmez.
/// Bu tip actor içinde kurulup tüketilir; sınırı geçen veri actor'a girerken düzleştirilmelidir.
struct PropertyOps {
    var set: [String: Any?]?
    var setOnce: [String: Any?]?
    var unset: [String]?
    var add: [String: Any?]?

    init(
        set: [String: Any?]? = nil,
        setOnce: [String: Any?]? = nil,
        unset: [String]? = nil,
        add: [String: Any?]? = nil
    ) {
        self.set = set
        self.setOnce = setOnce
        self.unset = unset
        self.add = add
    }
}

/// SDK'nın sunucuyla konuştuğu tek dil (SPEC §2). Gövdede fazladan ya da yanlış bir alan
/// sunucunun bütün event'i düşürmesine yol açar; bu yüzden alanlar burada tek yerde kurulur.
///
/// Serileştirme `JSONSerialization` ile yapılır ve anahtar sırası garanti etmez: sunucu sıra
/// beklemiyor, `.sortedKeys` gereksiz kısıt olurdu.
enum EventJSON {
    /// Tek event'in JSON satırı (kuyruğa ham metin olarak girer).
    ///
    /// Değerler önce `sanitize` edilir; böylece NaN/Infinity ya da desteklenmeyen bir tip event'i
    /// düşürmez, yalnız o değer `null` olur. Sanitize sonrası serileştirme fırlatamaz; yine de
    /// fırlarsa boş satır döner: `EventQueue.append` boş satırı yok sayar, aksi halde bozuk bir
    /// satır kuyruğa girip gönderimi tıkardı.
    static func event(
        name: String,
        distinctId: String,
        time: Int64,
        insertId: String,
        sessionId: String,
        props: [String: Any?]?,
        ops: PropertyOps,
        userId: String?,
        context: [String: Any?]
    ) -> String {
        var o: [String: Any] = [
            "event": name,
            "distinct_id": distinctId,
            "time": time,
            "insert_id": insertId,
            "session_id": sessionId,
            "context": sanitizeMap(context),
        ]
        // Boş map/dizi yazılmaz: sunucu `$` önekli prop anahtarında event'i düşürür, boş bir
        // operasyon nesnesi de bu riske girmesin.
        if let props, !props.isEmpty { o["props"] = sanitizeMap(props) }
        if let set = ops.set, !set.isEmpty { o["$set"] = sanitizeMap(set) }
        if let setOnce = ops.setOnce, !setOnce.isEmpty { o["$set_once"] = sanitizeMap(setOnce) }
        if let unset = ops.unset, !unset.isEmpty { o["$unset"] = unset }
        if let add = ops.add, !add.isEmpty { o["$add"] = sanitizeMap(add) }
        if let userId, !userId.isEmpty { o["user_id"] = userId }

        guard JSONSerialization.isValidJSONObject(o),
              let data = try? JSONSerialization.data(withJSONObject: o) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Kuyruktan gelen ham satırlardan gönderim gövdesi. Zehirli satırı (yarım yazılmış, JSON
    /// olmayan ya da nesne olmayan) atlar ve sayısını döndürür: fırlatsaydık gönderim aynı satırda
    /// sonsuza dek tıkanırdı. Satırlar çözülüp yeniden kodlanır, string olarak gömülmez.
    static func batch(sentAt: Int64, lines: [String]) -> (body: String, skipped: Int) {
        var events: [[String: Any]] = []
        var skipped = 0
        for line in lines {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] {
                events.append(obj)
            } else {
                skipped += 1
            }
        }
        let root: [String: Any] = ["sent_at": sentAt, "events": events]
        // Kökü biz kurduk, değerler zaten çözülmüş geçerli JSON: fırlatması beklenmez.
        let data = (try? JSONSerialization.data(withJSONObject: root)) ?? Data("{\"sent_at\":\(sentAt),\"events\":[]}".utf8)
        return (String(decoding: data, as: UTF8.self), skipped)
    }

    // MARK: - Değer temizliği

    private static func sanitizeMap(_ map: [String: Any?]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(map.count)
        // Açık `nil` anahtarı silmez, `null` yazar: "bu alanı boşalt" ile "hiç gönderme" farklı şeylerdir.
        for (k, v) in map { out[k] = sanitize(v as Any) }
        return out
    }

    private static func sanitize(_ value: Any) -> Any {
        // Optional açık açılır: bilinmeyen tipler `String(describing:)` ile yazıldığından açılmayan
        // `.none` "nil" metnine, `.some(x)` "Optional(x)" metnine dönerdi (sessiz veri bozulması).
        if Mirror(reflecting: value).displayStyle == .optional {
            guard let wrapped = Mirror(reflecting: value).children.first?.value else { return NSNull() }
            return sanitize(wrapped)
        }
        switch value {
        case is NSNull:
            return NSNull()
        case let s as String:
            return s
        case let n as NSNumber:
            // Swift'in Bool/Int/Double/Float değerleri de NSNumber'a köprülenir; tek dal hepsini kapsar
            // ve Bool'un 1'e dönüşmesini önler. JSON'da NaN/Infinity yok: fırlatmak yerine `null`.
            return n.doubleValue.isFinite ? n : NSNull()
        case let d as [String: Any?]:
            return sanitizeMap(d)
        case let a as [Any?]:
            return a.map { sanitize($0 as Any) }
        case let d as Date:
            // Protokoldeki `time` ile aynı birim (epoch ms).
            // `Int64(Double)` taşmada trap eder ve ev sahibi uygulamayı çökertir; `isFinite` taşmayı elemez
            // (1e300 sonlu). `Int64(exactly:)` NaN, sonsuz ve aralık dışında `nil` verir; `Double(Int64.max)`
            // yuvarlamayla 2^63'e çıktığı için `<= Double(Int64.max)` karşılaştırması ise güvenli değildir.
            // Aralık dışı kalan tarih, diğer bilinmeyen tipler gibi metin olarak yazılır (`null` veri kaybı olurdu).
            let ms = (d.timeIntervalSince1970 * 1000).rounded()
            if let exact = Int64(exactly: ms) { return exact }
            return String(describing: d)
        case let u as URL:
            return u.absoluteString
        default:
            // Android bilinmeyen tipte `toString()` yazar; `null` görünmez veri kaybı olurdu.
            // Fırlatmak da event'i düşürürdü.
            return String(describing: value)
        }
    }
}

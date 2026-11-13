import Foundation

/// Attribution sinyalinin kalıcı "bekliyor" durumu (SPEC §8.2).
///
/// Neden var: 0.3.0 sinyali bir kez gönderiyordu. İlk açılışta ağ yoksa ya da sunucu o an 5xx
/// döndüyse kurulumun hangi reklamdan geldiği kayboluyordu (Apple token'ı 24 saat yaşar). Durum,
/// sunucu `2xx` dönene kadar "bekliyor" kalır; her denemede **taze** token üretilir, token diske
/// yazılmaz.
///
/// `insertId` ve `firstSignalAtMs` tekrarlarda değişmez: sunucu (`PROTOCOL.md` §9) tekrarı
/// `insert_id` + zamanla ayıklar ve olayın zamanı kurulum anı kalır.
package struct AttributionState: Sendable, Equatable {
    package var pending: Bool
    package var insertId: String
    /// Sinyalin ilk üretildiği an (epoch ms). Gövdede `time` olarak gider.
    package var firstSignalAtMs: Int64
    /// Son BAŞARIYLA giden ATT durumu (`nil`: okunmadan gitti ya da 0.3.0'dan devralındı).
    package var sentAttStatus: String?
    /// Son başarıyla giden rota: `identified` / `anonymous` (`nil`: 0.3.0'dan devralındı).
    package var sentRoute: String?
    package var attempts: Int

    package init(pending: Bool, insertId: String, firstSignalAtMs: Int64,
                 sentAttStatus: String? = nil, sentRoute: String? = nil, attempts: Int = 0) {
        self.pending = pending
        self.insertId = insertId
        self.firstSignalAtMs = firstSignalAtMs
        self.sentAttStatus = sentAttStatus
        self.sentRoute = sentRoute
        self.attempts = attempts
    }
}

/// Durum okumasının sonucu. "Yok", "okunamıyor" ve "yazılamaz" ayrı durumlardır: kilitli cihazda
/// (prewarm) okunamayan kayıt "yok" sanılırsa sinyal ikinci kez üretilirdi.
package enum AttributionStateLoad: Sendable, Equatable {
    /// Rıza kalıcı iz bırakmaya izin vermiyor ya da SDK kurulmadı: durum yalnız süreç belleğinde.
    case unavailable
    /// Kayıt var olabilir ama okunamadı (veri koruması): bu tur atlanır.
    case unreadable
    /// Kayıt yok. `priorLaunch`: bu süreç başlamadan önce SDK bu cihazda en az bir kez açılmıştı
    /// (yaşam döngüsü durumu vardı) — 0.3.0'dan yükseltme (SPEC §8.2, geçiş).
    case absent(priorLaunch: Bool)
    case present(AttributionState)
}

/// iOS/macOS: `<queueDirectory>/attribution` dosyası, yedekten hariç, atomik yazım.
/// tvOS: `UserDefaults` (`cz_attribution_state`). Kuyruk dizininde durduğu için rıza geri
/// alınınca (`Core.erase`) kuyrukla birlikte silinir.
struct AttributionStateStore: Sendable {
    let platform: Platform
    let defaultsSuite: String?

    static let defaultsKey = "cz_attribution_state"

    private var usesDefaults: Bool { platform.name == "tvos" }
    private var file: URL { platform.queueDirectory.appendingPathComponent("attribution") }
    private var defaults: UserDefaults { defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    enum Loaded: Sendable, Equatable {
        case absent
        case unreadable
        case value(AttributionState)
    }

    /// Salt okuma: dizin ya da dosya yaratmaz. Ayrıştırılamayan kayıt yok sayılır (yeniden
    /// yazılır); token taşımadığı için kaybı yalnız tekrar ayıklamasını bir kez bozar.
    func load() -> Loaded {
        let data: Data
        if usesDefaults {
            guard let s = defaults.string(forKey: Self.defaultsKey) else { return .absent }
            data = Data(s.utf8)
        } else {
            do {
                data = try Data(contentsOf: file)
            } catch {
                return DeviceIdStore.isNoSuchFile(error) ? .absent : .unreadable
            }
        }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pending = o["pending"] as? Bool,
              let insertId = o["insert_id"] as? String, !insertId.isEmpty,
              let first = (o["first_signal_at_ms"] as? NSNumber)?.int64Value
        else { return .absent }
        return .value(AttributionState(
            pending: pending, insertId: insertId, firstSignalAtMs: first,
            sentAttStatus: o["sent_att_status"] as? String,
            sentRoute: o["sent_route"] as? String,
            attempts: (o["attempts"] as? NSNumber)?.intValue ?? 0))
    }

    func save(_ s: AttributionState) -> Bool {
        var o: [String: Any] = [
            "pending": s.pending, "insert_id": s.insertId,
            "first_signal_at_ms": NSNumber(value: s.firstSignalAtMs), "attempts": s.attempts,
        ]
        if let v = s.sentAttStatus { o["sent_att_status"] = v }
        if let v = s.sentRoute { o["sent_route"] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return false }
        if usesDefaults {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}

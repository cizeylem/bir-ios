import Foundation

/// Oturum penceresi: `session_id` oturum başlangıcının epoch ms'idir (string); `timeout`
/// kadar hareketsizlik yeni oturum açar. Pencere kayar: her çağrı son etkinliği yeniler.
///
/// Durum diskte `<başlangıç>|<son etkinlik>` düz metin (iki tamsayı, ms) olarak durur ki süreç
/// ölüp açıldığında pencere içindeyse oturum sürsün. Kalıcılık en-iyi-çaba: yazılamazsa oturum
/// bellekte işler, fırlatılmaz. Okunamayan ya da bozuk dosya "oturum yok" demektir ve yeni oturum
/// başlar; kimlikten (`device_id`) farklı olarak bu kayıp zararsızdır, bir sonraki yazım dosyayı düzeltir.
///
/// Bilerek `Sendable` DEĞİL ve kendi kilidi yok (`EventQueue` ile aynı kalıp): mutasyon taşır,
/// sahibi (actor) izole eder, derleyici de tipin actor sınırından kaçmadığını kanıtlar.
final class SessionStore {
    /// `last` yalnız kayan pencere için tutulur; çökmede en çok bu kadar eskir ve bu kabul edilebilir.
    /// Her event'te diske yazmak (ve fsync) maliyetine değmez.
    private static let persistIntervalMs: Int64 = 60_000

    private let url: URL
    private let now: @Sendable () -> Double
    private let timeoutMs: Int64

    private var start: Int64?
    private var last: Int64 = 0
    /// Son başarılı (ya da denenen) yazımın zamanı; başarısız yazımda da ilerler ki her çağrıda tekrar denenmesin.
    private var lastWrite: Int64 = 0

    /// - Parameters:
    ///   - now: epoch saniyesi.
    ///   - timeout: saniye.
    init(url: URL, now: @escaping @Sendable () -> Double, timeout: Double = 1800) {
        self.url = url
        self.now = now
        self.timeoutMs = Int64((timeout * 1000).rounded())
        load()
    }

    func current() -> String {
        let t = Self.ms(now())

        // Sınır dahil: tam `timeout` hâlâ aynı oturum, bir ms fazlası yeni oturum.
        // Saat geri giderse fark negatiftir ve oturum bölünmez: kullanıcı saati elle oynatmış ya da
        // NTP düzeltmesi olabilir, bunu "hareketsizlik" saymak oturum sayısını şişirirdi. `last` yine
        // de yeni saate çekilir; yoksa sonraki pencere gerçek geçen süreye değil eski ileri tarihe göre ölçülürdü.
        let continues = start != nil && t - last <= timeoutMs
        let startedNew = !continues
        if startedNew { start = t }
        last = t

        // `t < lastWrite`: saat geri gittiyse "60 sn geçti mi" ölçüsü anlamsızlaşır; diski bir kez güncelle.
        if startedNew || t - lastWrite >= Self.persistIntervalMs || t < lastWrite {
            persist(t)
        }
        return String(start ?? t)
    }

    /// Bir sonraki `current()` yeni oturum açar. Dosya da silinir ki yeniden başlatma eski oturumu sürdürmesin.
    func reset() {
        start = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - İç

    private static func ms(_ seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let s = Int64(parts[0]), let l = Int64(parts[1]) else { return }
        start = s
        last = l
        lastWrite = l
    }

    private func persist(_ t: Int64) {
        lastWrite = t
        guard let start else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(start)|\(last)".utf8).write(to: url, options: .atomic)
        } catch {
            // En-iyi-çaba: oturum bellekte sürer.
        }
    }
}

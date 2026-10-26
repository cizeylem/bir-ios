import Foundation

/// `Transport`'un `Dispatcher`'a görünen yüzü. Döngü durum kodunu görmez, yalnız `Outcome` görür;
/// protokol, testlerin gerçek ağ yerine sahte koyabilmesi için var.
protocol BatchSending: Sendable {
    func send(body: String) async -> (Outcome, retryAfter: Double?)
}

extension Transport: BatchSending {}

/// Kuyruğu sunucuya boşaltan döngü. `bir-js`'teki `drain()` ve `scheduleBackoff()` ile birebir.
///
/// Veri kaybının en kolay olduğu yer burası; bu yüzden kural tek: yalnız sunucu açıkça kabul
/// ettiyse (`ok`), kalıcı reddettiyse (`drop`) ya da tek başına sığmayan event'i reddettiyse
/// (`split`, tek event) satır silinir. `retry` hiçbir şeyi silmez ve `insert_id` değişmez.
///
/// Zaman birimi SANİYE (epoch): `Retry-After` ve takvim de saniye. `sent_at` milisaniyeye çevrilir.
actor Dispatcher {
    struct Stats: Sendable {
        let queued: Int
        let dropped: Int
        let rejected: Int
        let disabled: Bool
    }

    static let maxBatchEvents = 500
    /// Sıkıştırılmamış gövde sınırı. Şartname sıkıştırılmış 1 MB der; sıkıştırılmamışı saymak
    /// daha muhafazakâr, bilinçli.
    static let maxBatchBytes = 1_048_576
    /// Takvim adımları (sn). Tavan yalnız takvime uygulanır, `Retry-After`'a değil.
    static let schedule: [Double] = [1, 8, 32, 128, 300]

    private let queue: EventQueue
    private let transport: BatchSending
    private let now: @Sendable () -> Double
    private let random: @Sendable () -> Double

    private var disabled = false
    private var rejected = 0
    /// Takvimin son adımı (sn); 0 = backoff yok.
    private var backoffStep: Double = 0
    private var backoffUntil: Double = 0
    private var inFlight: Task<Void, Never>?

    init(
        queue: EventQueue,
        transport: BatchSending,
        now: @escaping @Sendable () -> Double,
        random: @escaping @Sendable () -> Double
    ) {
        self.queue = queue
        self.transport = transport
        self.now = now
        self.random = random
    }

    var isDisabled: Bool { disabled }

    func stats() -> Stats {
        Stats(queued: queue.count, dropped: queue.droppedCount, rejected: rejected, disabled: disabled)
    }

    /// Kuyruğa satır ekler. Kuyruk actor'a ait olduğu için dışarıdan tek giriş bu.
    func enqueue(_ line: String) {
        queue.append(line)
    }

    /// Aynı anda yalnız bir boşaltma çalışır; ikinci çağrı devam edeni bekler. Actor, `await`
    /// noktalarında yeniden girilebilir: bu koruma olmasa iki döngü aynı batch'i iki kez gönderirdi.
    func drain() async {
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await self.run() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    // MARK: - Döngü

    private func run() async {
        if disabled { return }
        if queue.count == 0 { return }
        if now() < backoffUntil { return }

        var size = Dispatcher.maxBatchEvents
        // Her tur ya kuyruktan en az bir satır siler, ya `size`'ı küçültür, ya da döner:
        // `split` tek event'te silerek, birden çoklu batch'te yarıya indirerek ilerler.
        while queue.count > 0 && !disabled {
            let batch = nextBatch(limit: size)
            guard !batch.isEmpty else { return }
            let (body, skipped) = EventJSON.batch(sentAt: sentAt(), lines: batch)

            // Hepsi bozuksa boş gövde göndermek anlamsız, satırları bırakmak ise poison message:
            // gönderim o satırda sonsuza dek tıkanır. Ağa çıkılmadığı için backoff'a dokunulmaz.
            if skipped >= batch.count {
                rejected += batch.count
                queue.removeFirst(batch.count)
                continue
            }

            // `await` sırasında kuyruk başı budanmış olabilir (taşma); `removeFirst(n)` o durumda
            // gönderilmemiş yeni satırları silerdi. Budananı düşüp yalnız kalanı sileriz.
            let droppedBefore = queue.droppedCount
            let (outcome, retryAfter) = await transport.send(body: body)
            let lost = max(0, queue.droppedCount - droppedBefore)
            let remaining = max(0, batch.count - lost)

            switch outcome {
            case .retry:
                scheduleBackoff(explicit: retryAfter)
                return
            case .fatal:
                disabled = true
                return
            case .split:
                if batch.count == 1 {
                    // Tek event bile sığmıyor: sonsuz döngüye girmemek için düşür.
                    rejected += remaining
                    queue.removeFirst(remaining)
                } else {
                    size = (batch.count + 1) / 2
                }
            case .drop:
                rejected += remaining
                queue.removeFirst(remaining)
                resetBackoff()
            case .ok:
                rejected += min(skipped, remaining)
                queue.removeFirst(remaining)
                resetBackoff()
            }
        }
    }

    /// En fazla `limit` (ve 500) satır, toplam UTF-8 uzunluğu 1 MB'ı aşmayacak kadar. İlk satır
    /// tek başına sınırı aşsa da alınır: yoksa o satır kuyruğu sonsuza dek tıkar.
    private func nextBatch(limit: Int) -> [String] {
        let cap = max(1, min(limit, Dispatcher.maxBatchEvents))
        var taken: [String] = []
        var bytes = 0
        for line in queue.peek(cap) {
            let n = line.utf8.count
            if !taken.isEmpty && bytes + n > Dispatcher.maxBatchBytes { break }
            taken.append(line)
            bytes += n
        }
        return taken
    }

    // MARK: - Backoff

    private func scheduleBackoff(explicit: Double?) {
        if let explicit, explicit.isFinite, explicit >= 0 {
            // Tavan yok: sunucu ne dediyse o. Takvim ise bu değerden (kelepçeli) devam eder.
            backoffStep = min(max(explicit, Dispatcher.schedule[0]), Dispatcher.schedule[Dispatcher.schedule.count - 1])
            backoffUntil = now() + explicit
            return
        }
        let next = Dispatcher.schedule.first { $0 > backoffStep } ?? Dispatcher.schedule[Dispatcher.schedule.count - 1]
        backoffStep = next
        // Jitter aşağı yönlü: [%50, %100]. Yukarı yönlü olsaydı 300 sn tavanı aşılırdı.
        let r = random()
        let unit = r.isFinite ? min(max(r, 0), 1) : 1
        backoffUntil = now() + next * (0.5 + 0.5 * unit)
    }

    private func resetBackoff() {
        backoffStep = 0
        backoffUntil = 0
    }

    /// Duvar saati, ms. Sonlu olmayan ya da Int64'e sığmayan değer 0'a düşer: dönüşüm trap eder.
    private func sentAt() -> Int64 {
        let ms = now() * 1000
        guard ms.isFinite, abs(ms) < 9.0e18 else { return 0 }
        return Int64(ms)
    }
}

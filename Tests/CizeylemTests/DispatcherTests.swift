import XCTest
@testable import Cizeylem

/// Sahte saat (ms). `now` kapanışı `@Sendable`; değişebilir durum `@unchecked` kaçışı olmadan bir
/// dosyada tutulur (bkz. SessionStoreTests).
private final class Clock: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cz-dclock-\(UUID().uuidString)")

    init(ms: Int64 = 1_760_000_000_000) { set(ms) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func set(_ ms: Int64) { try? Data(String(ms).utf8).write(to: url) }
    func advance(_ ms: Int64) { set(ms_ + ms) }
    private var ms_: Int64 { Self.read(url) }
    var seconds: @Sendable () -> Double { { [url] in Double(Self.read(url)) / 1000 } }

    private static func read(_ url: URL) -> Int64 {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int64($0) } ?? 0
    }
}

/// Sahte ağ: her çağrıyı (gövdeden çıkan `insert_id`'ler) kaydeder, yanıtı `responder` verir.
/// Sonsuz döngü hatası testi sonsuza dek asmasın diye 2.000. çağrıdan sonra `fatal` döner.
private actor FakeNet: BatchSending {
    typealias Responder = @Sendable (Int, [String]) async -> (Outcome, Double?)
    private(set) var calls: [[String]] = []
    private(set) var bodies: [String] = []
    private let responder: Responder

    init(_ responder: @escaping Responder = { _, _ in (.ok, nil) }) { self.responder = responder }

    func send(body: String) async -> (Outcome, retryAfter: Double?) {
        let idx = calls.count
        let ids = FakeNet.ids(body)
        calls.append(ids)
        bodies.append(body)
        if idx >= 2000 { return (.fatal, nil) }
        let (o, r) = await responder(idx, ids)
        return (o, r)
    }

    var sizes: [Int] { calls.map(\.count) }

    static func ids(_ body: String) -> [String] {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let events = o["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { $0["insert_id"] as? String }
    }
}

final class DispatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cz-disp-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Yardımcılar

    private func line(_ i: Int, pad: Int = 0) -> String {
        "{\"event\":\"e\",\"insert_id\":\"id-\(i)\",\"p\":\"\(String(repeating: "a", count: pad))\"}"
    }

    private func make(
        _ lines: [String],
        net: FakeNet,
        clock: Clock,
        random: @escaping @Sendable () -> Double = { 1 },
        maxEvents: Int = 5000,
        maxBytes: Int = 200_000_000
    ) -> Dispatcher {
        let q = EventQueue(directory: dir, maxEvents: maxEvents, maxBytes: maxBytes)
        for l in lines { q.append(l) }
        return Dispatcher(queue: q, transport: net, now: clock.seconds, random: random)
    }

    private func lines(_ n: Int, from: Int = 1) -> [String] { (from..<(from + n)).map { line($0) } }

    // MARK: - Sonuçlar

    func test200SonrasiEventlerKuyruktanSilinir() async {
        let net = FakeNet()
        let d = make(lines(3), net: net, clock: Clock())
        await d.drain()
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 0)
        let calls = await net.calls
        XCTAssertEqual(calls, [["id-1", "id-2", "id-3"]])
    }

    func testBosKuyrukAgaCikmaz() async {
        let net = FakeNet()
        let d = make([], net: net, clock: Clock())
        await d.drain()
        let n = await net.calls.count
        XCTAssertEqual(n, 0)
    }

    func test413teBatchIkiyeBolunur() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.split, nil) : (.ok, nil) }
        let d = make(lines(4), net: net, clock: Clock())
        await d.drain()
        let calls = await net.calls
        XCTAssertEqual(calls, [["id-1", "id-2", "id-3", "id-4"], ["id-1", "id-2"], ["id-3", "id-4"]])
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 0, "bölünen event reddedilmiş sayılmaz")
    }

    func testTekSayidaBatchYukariYuvarlanarakBolunur() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.split, nil) : (.ok, nil) }
        let d = make(lines(5), net: net, clock: Clock())
        await d.drain()
        let sizes = await net.sizes
        XCTAssertEqual(sizes, [5, 3, 2])
    }

    func testBolunmeSonrakiBatchlereDeSurer() async {
        // Referanstaki gibi `size` döngü boyunca küçük kalır.
        let net = FakeNet { idx, _ in idx == 0 ? (.split, nil) : (.ok, nil) }
        let d = make(lines(1000), net: net, clock: Clock())
        await d.drain()
        let sizes = await net.sizes
        XCTAssertEqual(sizes, [500, 250, 250, 250, 250])
    }

    func testTekEvent413AlirsaDusurulurVeDonguKilitlenmez() async {
        let net = FakeNet { _, _ in (.split, nil) }
        let d = make(lines(2), net: net, clock: Clock())
        await d.drain()
        let sizes = await net.sizes
        XCTAssertEqual(sizes, [2, 1, 1])
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 2)
        XCTAssertFalse(s.disabled, "sahte ağın güvenlik valfi (fatal) tetiklenmiş olmamalı")
    }

    func testHerCagriBolunurseDeSonlanir() async {
        let net = FakeNet { _, _ in (.split, nil) }
        let d = make(lines(37), net: net, clock: Clock())
        await d.drain()
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 37)
        XCTAssertFalse(s.disabled)
        let n = await net.calls.count
        XCTAssertLessThan(n, 200)
    }

    func test401SonrasiDisabledOlurVeTekrarGonderilmez() async {
        let net = FakeNet { _, _ in (.fatal, nil) }
        let clock = Clock()
        let d = make(lines(3), net: net, clock: clock)
        await d.drain()
        var disabled = await d.isDisabled
        XCTAssertTrue(disabled)
        clock.advance(86_400_000)
        await d.drain()
        await d.drain()
        let n = await net.calls.count
        XCTAssertEqual(n, 1)
        let s = await d.stats()
        XCTAssertTrue(s.disabled)
        XCTAssertEqual(s.queued, 3, "fatal kuyruğu silmez")
        disabled = await d.isDisabled
        XCTAssertTrue(disabled)
    }

    func test400BatchiSilerAmaTekrarDenemez() async {
        let net = FakeNet { _, _ in (.drop, nil) }
        let d = make(lines(3), net: net, clock: Clock())
        await d.drain()
        await d.drain()
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 3)
        let n = await net.calls.count
        XCTAssertEqual(n, 1)
    }

    func test400SonrakiBatchlereDevamEder() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.drop, nil) : (.ok, nil) }
        let d = make(lines(700), net: net, clock: Clock())
        await d.drain()
        let sizes = await net.sizes
        XCTAssertEqual(sizes, [500, 200])
        let s = await d.stats()
        XCTAssertEqual(s.rejected, 500)
        XCTAssertEqual(s.queued, 0)
    }

    func test5xxteKuyrukAynenKalirAyniInsertIdIleTekrar() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.retry, nil) : (.ok, nil) }
        let clock = Clock()
        let src = lines(3)
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        for l in src { q.append(l) }
        let d = Dispatcher(queue: q, transport: net, now: clock.seconds, random: { 1 })
        await d.drain()
        var s = await d.stats()
        XCTAssertEqual(s.queued, 3)
        XCTAssertEqual(s.rejected, 0)
        // Dosyadaki satırlar bayt bayt aynı.
        let onDisk = (try? String(contentsOf: dir.appendingPathComponent("queue.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertEqual(onDisk, src.map { $0 + "\n" }.joined())
        clock.advance(1_000)
        await d.drain()
        let calls = await net.calls
        XCTAssertEqual(calls.count, 2)
        guard calls.count == 2 else { return }
        XCTAssertEqual(calls[0], calls[1], "aynı insert_id dizisi")
        XCTAssertEqual(calls[1], ["id-1", "id-2", "id-3"])
        s = await d.stats()
        XCTAssertEqual(s.queued, 0)
    }

    func testRetryIlkBatchteDonerKalaniDenemez() async {
        let net = FakeNet { _, _ in (.retry, nil) }
        let d = make(lines(1200), net: net, clock: Clock())
        await d.drain()
        let sizes = await net.sizes
        XCTAssertEqual(sizes, [500])
        let s = await d.stats()
        XCTAssertEqual(s.queued, 1200)
    }

    // MARK: - Backoff

    /// `wait` ms kala çağrı yok, tam `wait` ms sonra var.
    private func assertWaits(
        _ wait: Int64, net: FakeNet, clock: Clock, d: Dispatcher,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let before = await net.calls.count
        clock.advance(wait - 1)
        await d.drain()
        var n = await net.calls.count
        XCTAssertEqual(n, before, "\(wait - 1) ms sonra henüz gitmemeli", file: file, line: line)
        clock.advance(1)
        await d.drain()
        n = await net.calls.count
        XCTAssertEqual(n, before + 1, "\(wait) ms sonra gitmeli", file: file, line: line)
    }

    func testBackoffTakvimi1_8_32_128_300() async {
        let net = FakeNet { _, _ in (.retry, nil) }
        let clock = Clock()
        let d = make(lines(2), net: net, clock: clock)
        await d.drain()   // 1. başarısızlık: 1 sn
        for wait: Int64 in [1_000, 8_000, 32_000, 128_000, 300_000, 300_000, 300_000] {
            await assertWaits(wait, net: net, clock: clock, d: d)
        }
    }

    func testJitterAsagiYonluVeTakvimiAsmaz() async {
        // random = 0 → tam yarısı.
        let net0 = FakeNet { _, _ in (.retry, nil) }
        let c0 = Clock()
        let d0 = make(lines(1), net: net0, clock: c0, random: { 0 })
        await d0.drain()
        for wait: Int64 in [500, 4_000, 16_000, 64_000, 150_000, 150_000] {
            await assertWaits(wait, net: net0, clock: c0, d: d0)
        }
        // random = 0.5 → %75.
        let net5 = FakeNet { _, _ in (.retry, nil) }
        let c5 = Clock()
        let d5 = make(lines(1), net: net5, clock: c5, random: { 0.5 })
        await d5.drain()
        for wait: Int64 in [750, 6_000, 24_000, 96_000, 225_000] {
            await assertWaits(wait, net: net5, clock: c5, d: d5)
        }
    }

    func testAralikDisiRastgeleTakvimiAsmaz() async {
        // Üst sınır: bekleme hiçbir zaman takvim değerinden uzun olamaz (tam adımda gönderim var).
        for r in [2.0, 1e300, .infinity, .nan, -1.0, -.infinity] {
            let net = FakeNet { _, _ in (.retry, nil) }
            let clock = Clock()
            let d = make(lines(1), net: net, clock: clock, random: { r })
            await d.drain()
            for step: Int64 in [1_000, 8_000, 32_000, 128_000, 300_000] {
                let before = await net.calls.count
                clock.advance(step)
                await d.drain()
                let n = await net.calls.count
                XCTAssertEqual(n, before + 1, "r=\(r) adım=\(step)")
            }
        }
    }

    func testRetryAfterVarsaTakvimYerineOKullanilir() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.retry, 77) : (.retry, nil) }
        let clock = Clock()
        let d = make(lines(1), net: net, clock: clock)
        await d.drain()
        await assertWaits(77_000, net: net, clock: clock, d: d)
    }

    func testRetryAfterSonrasiTakvimKelepceliDegerdenDevamEder() async {
        // Retry-After takvimin YERİNE geçer: adım = min(max(77,1),300) = 77. Sonraki başlıksız
        // başarısızlıkta takvim 77'den büyük ilk değere gider, yani 128.
        let net = FakeNet { idx, _ in idx == 0 ? (.retry, 77) : (.retry, nil) }
        let clock = Clock()
        let d = make(lines(1), net: net, clock: clock)
        await d.drain()
        clock.advance(77_000)
        await d.drain()
        await assertWaits(128_000, net: net, clock: clock, d: d)
    }

    func testRetryAfterSifirHemenDenenirAmaTakvimiSifirlamaz() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.retry, 0) : (.retry, nil) }
        let clock = Clock()
        let d = make(lines(1), net: net, clock: clock)
        await d.drain()
        await d.drain()   // 0 sn: hemen yeniden denenebilir
        var n = await net.calls.count
        XCTAssertEqual(n, 2)
        // Adım 1'e kelepçelendi; sıradaki başlıksız başarısızlık 8 sn.
        await assertWaits(8_000, net: net, clock: clock, d: d)
        n = await net.calls.count
        XCTAssertEqual(n, 3)
    }

    func testCokBuyukRetryAfterKelepcelenmez() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.retry, 31_536_000) : (.ok, nil) }
        let clock = Clock()
        let d = make(lines(1), net: net, clock: clock)
        await d.drain()
        clock.advance(86_400_000)            // 1 gün
        await d.drain()
        clock.advance(31_536_000_000 - 86_400_000 - 1)
        await d.drain()
        var n = await net.calls.count
        XCTAssertEqual(n, 1, "1 yıldan 1 ms önce hâlâ beklemeli (300 sn tavanı uygulanmaz)")
        clock.advance(1)
        await d.drain()
        n = await net.calls.count
        XCTAssertEqual(n, 2)
    }

    func testSonluOlmayanRetryAfterTakvimeDoner() async {
        for bad in [Double.nan, .infinity, -3] {
            let net = FakeNet { _, _ in (.retry, bad) }
            let clock = Clock()
            let d = make(lines(1), net: net, clock: clock)
            await d.drain()
            await assertWaits(1_000, net: net, clock: clock, d: d)
        }
    }

    func testBasariliGonderimBackoffuSifirlar() async {
        // 1. ve 2. çağrı başarısız (1 sn, 8 sn), 3. başarılı, 4. başarısız → yine 1 sn.
        let net = FakeNet { idx, _ in (idx == 0 || idx == 1 || idx == 3) ? (.retry, nil) : (.ok, nil) }
        let clock = Clock()
        let d = make(lines(1), net: net, clock: clock)
        await d.drain()
        await assertWaits(1_000, net: net, clock: clock, d: d)
        await assertWaits(8_000, net: net, clock: clock, d: d)    // 3. çağrı: ok
        await d.enqueue(line(2))
        await d.drain()                                            // 4. çağrı: retry, adım 1
        await assertWaits(1_000, net: net, clock: clock, d: d)
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
    }

    func testDropBackoffuSifirlar() async {
        // Karar: referans gibi `drop` da sunucunun yanıt verdiğini gösterir, backoff sıfırlanır.
        let net = FakeNet { idx, _ in
            switch idx {
            case 0: return (.retry, nil)       // adım 1
            case 1: return (.retry, nil)       // adım 8
            case 2: return (.drop, nil)        // sıfırlar
            default: return (.retry, nil)      // yeniden 1
            }
        }
        let clock = Clock()
        let d = make(lines(2), net: net, clock: clock)
        await d.drain()
        await assertWaits(1_000, net: net, clock: clock, d: d)
        await assertWaits(8_000, net: net, clock: clock, d: d)    // drop
        await d.enqueue(line(9))
        await d.drain()
        await assertWaits(1_000, net: net, clock: clock, d: d)
    }

    func testBackoffAktifkenDrainAgaCikmaz() async {
        let net = FakeNet { _, _ in (.retry, nil) }
        let clock = Clock()
        let d = make(lines(1), net: net, clock: clock)
        await d.drain()
        for _ in 0..<5 { await d.drain() }
        let n = await net.calls.count
        XCTAssertEqual(n, 1)
    }

    // MARK: - Batch sınırları

    func test500tenBuyukKuyrukBirdenFazlaBatchOlarakGider() async {
        let net = FakeNet()
        let d = make(lines(1200), net: net, clock: Clock())
        await d.drain()
        let calls = await net.calls
        XCTAssertEqual(calls.map(\.count), [500, 500, 200])
        XCTAssertEqual(calls.flatMap { $0 }, (1...1200).map { "id-\($0)" }, "sıra ve eksiksizlik")
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
    }

    func testTam500EventTekBatch501IkiBatch() async {
        let n1 = FakeNet()
        let d1 = make(lines(500), net: n1, clock: Clock())
        await d1.drain()
        let s1 = await n1.sizes
        XCTAssertEqual(s1, [500])

        try? FileManager.default.removeItem(at: dir)
        let n2 = FakeNet()
        let d2 = make(lines(501), net: n2, clock: Clock())
        await d2.drain()
        let s2 = await n2.sizes
        XCTAssertEqual(s2, [500, 1])
    }

    /// Tam `bytes` UTF-8 baytlık geçerli satır.
    private func sized(_ i: Int, bytes: Int) -> String {
        let base = line(i).utf8.count
        return line(i, pad: bytes - base)
    }

    func testTam1MBTekBatch1MBArtiBirIkiBatch() async {
        let half = Dispatcher.maxBatchBytes / 2
        let n1 = FakeNet()
        let d1 = make([sized(1, bytes: half), sized(2, bytes: half)], net: n1, clock: Clock())
        await d1.drain()
        let s1 = await n1.sizes
        XCTAssertEqual(s1, [2], "toplam tam sınırda: tek batch")

        try? FileManager.default.removeItem(at: dir)
        let n2 = FakeNet()
        let d2 = make([sized(1, bytes: half), sized(2, bytes: half + 1)], net: n2, clock: Clock())
        await d2.drain()
        let s2 = await n2.sizes
        XCTAssertEqual(s2, [1, 1], "bir bayt fazla: ikiye ayrılır")
    }

    func testBayt1MBSayimiUTF8BaytiyleYapilirKarakterle() async {
        // Her satır 104.857 bayt ama yalnız ~64.857 karakter: 10 satır 1.048.570 bayt; 11. sınırı aşar.
        let target = 104_857
        func tr(_ i: Int) -> String {
            let base = line(i).utf8.count
            let k = 40_000
            let rest = target - base - 2 * k
            return "{\"event\":\"e\",\"insert_id\":\"id-\(i)\",\"p\":\"\(String(repeating: "ş", count: k))\(String(repeating: "a", count: rest))\"}"
        }
        let src = (1...25).map(tr)
        XCTAssertEqual(src[0].utf8.count, target)
        XCTAssertLessThan(src[0].count, target - 30_000, "karakter sayısı bayttan belirgin düşük")
        let net = FakeNet()
        let d = make(src, net: net, clock: Clock())
        await d.drain()
        let sizes = await net.sizes
        XCTAssertEqual(sizes, [10, 10, 5])
    }

    func test1MBiTekBasinaAsanSatirYineGonderilirKuyrukTikanmaz() async {
        let net = FakeNet { _, ids in ids.count == 1 && ids[0] == "id-1" ? (.split, nil) : (.ok, nil) }
        let big = sized(1, bytes: Dispatcher.maxBatchBytes + 500)
        let d = make([big, line(2)], net: net, clock: Clock())
        await d.drain()
        let calls = await net.calls
        XCTAssertEqual(calls, [["id-1"], ["id-2"]])
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 1)
    }

    // MARK: - Bozuk satırlar

    func testHepsiBozukBatchBosGovdeGondermezSatirlariSiler() async {
        let net = FakeNet()
        let d = make(["not json", "[1,2]", "{\"yarim\":", "\"str\""], net: net, clock: Clock())
        await d.drain()
        let n = await net.calls.count
        XCTAssertEqual(n, 0, "boş gövde ağa çıkmaz")
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0, "poison satırlar kuyrukta kalmaz")
        XCTAssertEqual(s.rejected, 0, "sunucu reddetmedi")
        let sk = await d.skippedCount()
        XCTAssertEqual(sk, 4)
    }

    func testOkunamayanSatirSilinirkenLoggerYazar() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var lines: [String] = []
            func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let box = Box()
        let q = EventQueue(directory: dir, maxEvents: 5000, maxBytes: 200_000_000)
        for l in ["çöp", "{\"yarim\":"] { q.append(l) }
        let d = Dispatcher(queue: q, transport: FakeNet(), now: Clock().seconds, random: { 1 }, log: { box.add($0) })
        await d.drain()
        XCTAssertEqual(box.all.count, 1)
        XCTAssertTrue(box.all.first?.contains("2 satır") ?? false, "kayıp sessiz değil: \(box.all)")
    }

    func testBozukSatirGecerlilerleKarisikGidiyorBozukOlanSkippedeSayilir() async {
        let net = FakeNet()
        let d = make([line(1), "çöp", line(2)], net: net, clock: Clock())
        await d.drain()
        let calls = await net.calls
        XCTAssertEqual(calls, [["id-1", "id-2"]])
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 0)
        let sk = await d.skippedCount()
        XCTAssertEqual(sk, 1)
    }

    func testBozukSatirRetryDeSilinmezVeSayilmaz() async {
        let net = FakeNet { idx, _ in idx == 0 ? (.retry, nil) : (.ok, nil) }
        let clock = Clock()
        let d = make([line(1), "çöp"], net: net, clock: clock)
        await d.drain()
        var s = await d.stats()
        XCTAssertEqual(s.queued, 2)
        XCTAssertEqual(s.rejected, 0)
        var sk = await d.skippedCount()
        XCTAssertEqual(sk, 0, "retry'da silinmedi, sayılmaz")
        clock.advance(1_000)
        await d.drain()
        s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.rejected, 0)
        sk = await d.skippedCount()
        XCTAssertEqual(sk, 1)
    }

    func testHepsiBozukBatchBackoffuSifirlamaz() async {
        // [bozuk, geçerli]: 1. çağrı retry (adım 1). Sonra 413 → tek tek: [bozuk] ağsız silinir
        // (sıfırlama yok), [geçerli] retry → adım 1'den DEĞİL, 8'den devam eder.
        let net = FakeNet { idx, _ in
            switch idx {
            case 0: return (.retry, nil)
            case 1: return (.split, nil)
            default: return (.retry, nil)
            }
        }
        let clock = Clock()
        let d = make(["çöp", line(1)], net: net, clock: clock)
        await d.drain()
        clock.advance(1_000)
        await d.drain()                 // çağrı 2: split; [çöp] silinir; çağrı 3: [id-1] retry
        let calls = await net.calls
        XCTAssertEqual(calls, [["id-1"], ["id-1"], ["id-1"]])
        await assertWaits(8_000, net: net, clock: clock, d: d)
    }

    func testBozukSatirDropdaYalnizBirKezSayilir() async {
        let net = FakeNet { _, _ in (.drop, nil) }
        let d = make([line(1), "çöp", line(2)], net: net, clock: Clock())
        await d.drain()
        let s = await d.stats()
        XCTAssertEqual(s.rejected, 2, "yalnız sunucuya giden iki geçerli satır")
        let sk = await d.skippedCount()
        XCTAssertEqual(sk, 1)
        XCTAssertEqual(s.queued, 0)
    }

    func testBozukSatirRetryVeSplitTurlarindaSismez() async {
        // [bozuk, e1, e2]: retry, retry, split, split, ok. Bozuk satır tek kez sayılır.
        let net = FakeNet { idx, _ in
            switch idx {
            case 0, 1: return (.retry, nil)
            case 2: return (.split, nil)
            default: return (.ok, nil)
            }
        }
        let clock = Clock()
        let d = make(["çöp", line(1), line(2)], net: net, clock: clock)
        await d.drain()
        clock.advance(1_000)
        await d.drain()
        clock.advance(8_000)
        await d.drain()
        let sk = await d.skippedCount()
        XCTAssertEqual(sk, 1)
        let s = await d.stats()
        XCTAssertEqual(s.rejected, 0)
        XCTAssertEqual(s.queued, 0)
    }

    func testRejectedYalnizDropVeTekEventSplitteArtar() async {
        // ok, retry, bölünüp ok: rejected 0.
        let net = FakeNet { idx, _ in idx == 0 ? (.split, nil) : (.ok, nil) }
        let d = make(lines(4), net: net, clock: Clock())
        await d.drain()
        let a = await d.stats()
        XCTAssertEqual(a.rejected, 0)
        // drop: artar. tek event split: artar.
        let net2 = FakeNet { idx, _ in idx == 0 ? (.drop, nil) : (.split, nil) }
        try? FileManager.default.removeItem(at: dir)
        let d2 = make(lines(3) + [line(10)], net: net2, clock: Clock(), maxEvents: 5000)
        await d2.drain()
        let b = await d2.stats()
        XCTAssertEqual(b.rejected, 4)
        let sk = await d2.skippedCount()
        XCTAssertEqual(sk, 0)
    }

    // MARK: - Eşzamanlılık ve kuyruk taşması

    func testEszamanliIkiDrainAyniBatchiIkiKezGondermez() async {
        let net = FakeNet { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return (.ok, nil)
        }
        let d = make(lines(3), net: net, clock: Clock())
        async let a: Void = d.drain()
        async let b: Void = d.drain()
        _ = await (a, b)
        let calls = await net.calls
        XCTAssertEqual(calls.count, 1)
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
    }

    func testGonderimSirasindaBudananEventlerYuzundenYeniEventlerSilinmez() async {
        // Kuyruk sınırı 5. Batch (e1..e5) uçuştayken e6, e7 gelir ve e1, e2 budanır. Yanıt `ok`
        // gelince yalnız e3..e5 silinmeli; e6 ve e7 hiç gönderilmedi, kalmalı.
        let slot = Slot()
        let net = FakeNet { idx, _ in
            if idx == 0 {
                await slot.run()
            }
            return (.ok, nil)
        }
        let d = make(lines(5), net: net, clock: Clock(), maxEvents: 5, maxBytes: 1_000_000)
        let l6 = line(6), l7 = line(7)
        await slot.set { await d.enqueue(l6); await d.enqueue(l7) }
        await d.drain()
        // e6 ve e7 aynı boşaltmada, ayrı batch olarak gider: silinmiş olsalardı hiç gitmezlerdi.
        let calls = await net.calls
        XCTAssertEqual(calls, [["id-1", "id-2", "id-3", "id-4", "id-5"], ["id-6", "id-7"]])
        let s = await d.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.dropped, 2)
    }

    // MARK: - Saat

    func testSentAtMilisaniyedirVeSonluOlmayanSaatCokmez() async {
        let net = FakeNet()
        let clock = Clock(ms: 1_760_000_000_123)   // değişkende tutulur: deinit dosyayı siler
        let d = make(lines(1), net: net, clock: clock)
        await d.drain()
        let bodies = await net.bodies
        guard let body = bodies.first else { return XCTFail("gövde gönderilmedi") }
        let o = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        XCTAssertEqual((o?["sent_at"] as? NSNumber)?.int64Value, 1_760_000_000_123)

        try? FileManager.default.removeItem(at: dir)
        for bad in [Double.nan, .infinity, 1e300] {
            let n = FakeNet()
            let q = EventQueue(directory: dir, maxEvents: 10, maxBytes: 100_000)
            q.append(line(1))
            let d2 = Dispatcher(queue: q, transport: n, now: { bad }, random: { 1 })
            await d2.drain()
            let sizes = await n.sizes
            XCTAssertEqual(sizes, [1], "\(bad)")
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testStatsDroppedKuyrukTasmasindanGelir() async {
        let net = FakeNet()
        let d = make(lines(7), net: net, clock: Clock(), maxEvents: 5, maxBytes: 1_000_000)
        let s = await d.stats()
        XCTAssertEqual(s.queued, 5)
        XCTAssertEqual(s.dropped, 2)
    }
}

/// Testin yanıt sırasında çağıracağı eylemi sonradan bağlamak için (`Dispatcher` ancak `FakeNet`
/// kurulduktan sonra var olur). Actor, kapanışı `Sendable` kalır.
private actor Slot {
    private var action: (@Sendable () async -> Void)?
    func set(_ a: @escaping @Sendable () async -> Void) { action = a }
    func run() async { await action?() }
}

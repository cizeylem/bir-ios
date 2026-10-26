import XCTest
@testable import Cizeylem

/// Sahte saat: `now` kapanışı `@Sendable` olmak zorunda, değişebilir durum ise `Sendable` bir sınıfta
/// kaçışsız tutulamıyor (`Mutex` macOS 15+, `UserDefaults` Sendable değil). Değeri bir dosyada tutmak
/// tek `URL` yeter (`URL` Sendable); `@unchecked Sendable` kaçışı gerekmez.
private final class TestClock: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cz-clock-\(UUID().uuidString)")

    init(startMs: Int64) { set(ms: startMs) }

    deinit { try? FileManager.default.removeItem(at: url) }

    func set(ms: Int64) { try? Data(String(ms).utf8).write(to: url) }
    func advance(ms: Int64) { set(ms: nowMs + ms) }
    var nowMs: Int64 { Self.read(url) }

    private static func read(_ url: URL) -> Int64 {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int64($0) } ?? 0
    }

    /// SessionStore saniye (epoch) bekler.
    var seconds: @Sendable () -> Double {
        { [url] in Double(Self.read(url)) / 1000 }
    }
}

final class SessionStoreTests: XCTestCase {
    private var dir: URL!
    private let t0: Int64 = 1_760_000_000_000
    private let minute: Int64 = 60_000

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cz-session-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("session") }

    private func store(_ clock: TestClock, url: URL? = nil) -> SessionStore {
        SessionStore(url: url ?? file, now: clock.seconds)
    }

    private func onDisk() throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    func testIlkCagriSimdikiZamaniOturumKimligiYapar() {
        let clock = TestClock(startMs: t0)
        XCTAssertEqual(store(clock).current(), "1760000000000")
    }

    func test30DkIcindekiCagriAyniOturumuDondurur() {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        let first = s.current()
        clock.advance(ms: 29 * minute)
        XCTAssertEqual(s.current(), first)
    }

    func testTam30DkAyniOturumdur() {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        let first = s.current()
        clock.advance(ms: 30 * minute)
        XCTAssertEqual(s.current(), first, "sınır dahil: tam 30 dk hâlâ aynı oturum")
    }

    func test30DkArtiBirMsYeniOturumBaslatir() {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        _ = s.current()
        clock.advance(ms: 30 * minute + 1)
        XCTAssertEqual(s.current(), String(t0 + 30 * minute + 1))
    }

    func test30DkGecinceYeniOturumBaslar() {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        let first = s.current()
        clock.advance(ms: 31 * minute)
        let second = s.current()
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second, String(t0 + 31 * minute))
    }

    func testPencereEtkinlikleKayar() {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        let first = s.current()
        // Her çağrı 20 dk arayla: toplam 2 saat, ama hiçbir boşluk 30 dk'yı aşmaz.
        for _ in 0..<6 {
            clock.advance(ms: 20 * minute)
            XCTAssertEqual(s.current(), first)
        }
    }

    func testResetSonrasiYeniOturum() {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        let first = s.current()
        clock.advance(ms: 5_000)
        s.reset()
        let second = s.current()
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second, String(t0 + 5_000))
    }

    func testResetDiskteDeOturumuSilerYenidenBaslatmaSurdurmez() throws {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        _ = s.current()
        s.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        clock.advance(ms: 1_000)
        XCTAssertEqual(store(clock).current(), String(t0 + 1_000))
    }

    func testResetSonrasiYeniOturum60SnIcindeYineHemenYazilir() throws {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        _ = s.current()
        clock.advance(ms: 5_000)
        s.reset()
        _ = s.current()
        XCTAssertEqual(try onDisk(), "\(t0 + 5_000)|\(t0 + 5_000)", "yeni oturum, yazım aralığına takılmadan yazılır")
    }

    func testKesirliSaniyeMsyeYuvarlanir() {
        // 0.7 ms: yuvarlama ...001, kırpma ...000 verirdi.
        let s = SessionStore(url: file, now: { 1_760_000_000.0007 })
        XCTAssertEqual(s.current(), "1760000000001")
    }

    func testYenidenAcilincePencereIcindeOturumSurer() {
        let clock = TestClock(startMs: t0)
        let first = store(clock).current()
        clock.advance(ms: 10 * minute)
        XCTAssertEqual(store(clock).current(), first)
    }

    func testYenidenAcilincePencereGecmisseYeniOturum() {
        let clock = TestClock(startMs: t0)
        _ = store(clock).current()
        clock.advance(ms: 30 * minute + 1)
        XCTAssertEqual(store(clock).current(), String(t0 + 30 * minute + 1))
    }

    func testDurumBicimiBaslangicBorusuSonEtkinlik() throws {
        let clock = TestClock(startMs: t0)
        _ = store(clock).current()
        XCTAssertEqual(try onDisk(), "\(t0)|\(t0)")
    }

    func testYeniOturumHemenDiskeYazilir() throws {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        _ = s.current()
        clock.advance(ms: 31 * minute)
        _ = s.current()
        let t1 = t0 + 31 * minute
        XCTAssertEqual(try onDisk(), "\(t1)|\(t1)")
    }

    func testDiskYazimiSonYazimdan60SnGecmedenYapilmaz() throws {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        _ = s.current()
        clock.advance(ms: 59_999)
        _ = s.current()
        XCTAssertEqual(try onDisk(), "\(t0)|\(t0)", "59.999 sn: henüz yazılmaz")
        clock.advance(ms: 1)
        _ = s.current()
        XCTAssertEqual(try onDisk(), "\(t0)|\(t0 + 60_000)", "tam 60 sn: yazılır")
    }

    func testYazimSayaciSonYazimdanOlculur() throws {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        _ = s.current()
        clock.advance(ms: 60_000)
        _ = s.current()          // yazıldı (t0+60s)
        clock.advance(ms: 59_999)
        _ = s.current()          // son yazımdan 59.999 sn: yazılmaz
        XCTAssertEqual(try onDisk(), "\(t0)|\(t0 + 60_000)")
    }

    func testGuncellemeAtomiktirEskiOkuyucuTutarliGorur() throws {
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        _ = s.current()
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        clock.advance(ms: 60_000)
        _ = s.current()
        // Atomik yazım dosyayı yerinde kırpmaz, yenisini üstüne taşır; açık tutan okuyucu eski bütünü görür.
        let old = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(old, "\(t0)|\(t0)")
    }

    func testBozukDosyaYeniOturumBaslatirVeSonrakiYazimdaDuzelir() throws {
        let garbage = ["", "abc", "123", "1|", "|2", "a|b", "1|2|3", "1.5|2", "-", "  "]
        for text in garbage {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            let clock = TestClock(startMs: t0)
            XCTAssertEqual(store(clock).current(), String(t0), "bozuk içerik: \(text.debugDescription)")
            XCTAssertEqual(try onDisk(), "\(t0)|\(t0)", "bozuk dosya düzelmeli: \(text.debugDescription)")
        }
    }

    func testGecerliGorunenAmaBicimiYanlisDosyaKabulEdilmez() throws {
        // Pencere içinde kalan gerçekçi değerler: yalnız biçim reddi yeni oturum başlatır.
        for text in ["\(t0)|\(t0)|3", "\(t0)||\(t0)", "\(t0)|\(t0)|"] {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            let clock = TestClock(startMs: t0 + minute)
            XCTAssertEqual(store(clock).current(), String(t0 + minute), text)
        }
    }

    func testBozukUTF8DosyaYeniOturumBaslatir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x7C, 0xC3]).write(to: file)
        let clock = TestClock(startMs: t0)
        XCTAssertEqual(store(clock).current(), String(t0))
    }

    func testSonuSatirSonuluDosyaOkunur() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("\(t0)|\(t0)\n".utf8).write(to: file)
        let clock = TestClock(startMs: t0 + minute)
        XCTAssertEqual(store(clock).current(), String(t0))
    }

    func testDizinYoksaYazimdaOlusturulur() throws {
        let nested = dir.appendingPathComponent("a/b/session")
        let clock = TestClock(startMs: t0)
        _ = store(clock, url: nested).current()
        XCTAssertEqual(try String(contentsOf: nested, encoding: .utf8), "\(t0)|\(t0)")
    }

    func testYazilamazsaOturumBellekteSurer() throws {
        // Üst "dizin" aslında düz dosya: ne dizin kurulabilir ne dosya yazılabilir.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let unwritable = blocker.appendingPathComponent("session")
        let clock = TestClock(startMs: t0)
        let s = store(clock, url: unwritable)
        let first = s.current()
        XCTAssertEqual(first, String(t0))
        clock.advance(ms: 10 * minute)
        XCTAssertEqual(s.current(), first, "yazılamasa da pencere bellekte işler")
        clock.advance(ms: 31 * minute)
        XCTAssertEqual(s.current(), String(t0 + 41 * minute))
    }

    func testSaatGeriGidinceAyniOturumSurerVePencereYeniSaateGoreKayar() throws {
        // Davranış: negatif fark "hareketsizlik" sayılmaz, oturum bölünmez (kullanıcı saati elle
        // oynatmış ya da NTP düzeltmesi olabilir). Son etkinlik yeni saate çekilir ki sonraki
        // 30 dk, eski ileri tarihe değil gerçek geçen süreye göre ölçülsün.
        let clock = TestClock(startMs: t0)
        let s = store(clock)
        let first = s.current()
        clock.set(ms: t0 - 60 * minute)
        XCTAssertEqual(s.current(), first)
        XCTAssertEqual(try onDisk(), "\(t0)|\(t0 - 60 * minute)", "geri giden saat diske de yansır")
        clock.set(ms: t0 - 60 * minute + 30 * minute + 1)
        XCTAssertEqual(s.current(), String(t0 - 30 * minute + 1))
    }

    func testDiskteGelecekTarihliSonEtkinlikOturumuBolmez() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("\(t0)|\(t0 + 5 * minute)".utf8).write(to: file)
        let clock = TestClock(startMs: t0)
        XCTAssertEqual(store(clock).current(), String(t0))
    }
}

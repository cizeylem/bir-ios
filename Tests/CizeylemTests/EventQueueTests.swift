import XCTest
@testable import Cizeylem

final class EventQueueTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cz-queue-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("queue.jsonl") }

    private func physicalLines() throws -> [String] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func testAppendVePeekSirayiKorur() throws {
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        q.append("{\"a\":1}"); q.append("{\"a\":2}"); q.append("{\"a\":3}")
        XCTAssertEqual(q.peek(2), ["{\"a\":1}", "{\"a\":2}"])
        XCTAssertEqual(q.peek(10), ["{\"a\":1}", "{\"a\":2}", "{\"a\":3}"])
        XCTAssertEqual(q.count, 3)
        // Yeniden açılınca diskten aynı sırayla gelir.
        let q2 = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        XCTAssertEqual(q2.peek(10), ["{\"a\":1}", "{\"a\":2}", "{\"a\":3}"])
    }

    func testRemoveFirstGonderilenleriSiler() throws {
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        for i in 1...5 { q.append("{\"i\":\(i)}") }
        q.removeFirst(2)
        XCTAssertEqual(q.peek(10), ["{\"i\":3}", "{\"i\":4}", "{\"i\":5}"])
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(q.droppedCount, 0, "gönderilenler 'düşen' sayılmaz")
        XCTAssertEqual(try physicalLines(), ["{\"i\":3}", "{\"i\":4}", "{\"i\":5}"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".tmp"))
        q.removeFirst(99)
        XCTAssertEqual(q.count, 0)
        XCTAssertEqual(q.peek(5), [])
    }

    func testMaxEventsAsilincaEnEskilerDusurulur() throws {
        // pay = 10 satır: fiziksel sınır 110.
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 10_000_000)
        for i in 1...105 { q.append("{\"i\":\(i)}") }
        // Mantıksal görünüm: son 100.
        XCTAssertEqual(q.count, 100)
        XCTAssertEqual(q.droppedCount, 5)
        XCTAssertEqual(q.peek(1), ["{\"i\":6}"])
        XCTAssertEqual(q.peek(1000).last, "{\"i\":105}")
        XCTAssertEqual(q.peek(1000).count, 100)
        // Her append dosyayı yeniden yazmaz: pay dolana dek dosya büyür.
        XCTAssertEqual(try physicalLines().count, 105)
        // Eşik aşılınca tek seferde budanır.
        for i in 106...109 { q.append("{\"i\":\(i)}") }
        XCTAssertEqual(try physicalLines().count, 109, "pay dolmadan budama yok")
        q.append("{\"i\":110}")   // pay doldu: 110 satır -> tek seferde 100'e budanır
        XCTAssertEqual(try physicalLines().count, 100)
        q.append("{\"i\":111}")
        XCTAssertEqual(try physicalLines().count, 101)
        XCTAssertEqual(q.count, 100)
        XCTAssertEqual(q.droppedCount, 11)
        XCTAssertEqual(q.peek(1), ["{\"i\":12}"])
    }

    func testTasanDosyaYenidenAcilincaMantiksalGorunumeIner() throws {
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 10_000_000)
        for i in 1...105 { q.append("{\"i\":\(i)}") }
        XCTAssertEqual(try physicalLines().count, 105)
        let q2 = EventQueue(directory: dir, maxEvents: 100, maxBytes: 10_000_000)
        XCTAssertEqual(q2.count, 100)
        XCTAssertEqual(q2.peek(1), ["{\"i\":6}"])
        XCTAssertEqual(try physicalLines().count, 100)
    }

    func testDoluKuyrukHerAppendteDosyayiYenidenYazmaz() throws {
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 10_000_000)
        for i in 1...100 { q.append("{\"i\":\(i)}") }
        // Sınıra dayandık; sonraki 9 append'te dosya yerinde kalmalı (aynı dosya, sadece ekleme).
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        for i in 101...109 { q.append("{\"i\":\(i)}") }
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after, "replaceItemAt dosya kimliğini değiştirirdi")
        XCTAssertEqual(q.count, 100)
        XCTAssertEqual(q.peek(1), ["{\"i\":10}"])
    }

    func testMaxBytesAsilincaEnEskilerDusurulur() throws {
        // Her satır 10 bayt + satır sonu = 11; 55 bayt sınırı = 5 satır.
        let q = EventQueue(directory: dir, maxEvents: 1000, maxBytes: 55)
        for i in 10...19 { q.append("{\"id\":\(i)}") }   // 10 bayt
        XCTAssertEqual(q.count, 5)
        XCTAssertEqual(q.droppedCount, 5)
        XCTAssertEqual(q.peek(10), (15...19).map { "{\"id\":\($0)}" })
        let q2 = EventQueue(directory: dir, maxEvents: 1000, maxBytes: 55)
        XCTAssertEqual(q2.peek(10), (15...19).map { "{\"id\":\($0)}" })
    }

    func testYarimYazilmisSonSatirAtilir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"a\":1}\n{\"a\":2}\n{\"a\":3,\"yar".write(to: file, atomically: true, encoding: .utf8)
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        XCTAssertEqual(q.peek(10), ["{\"a\":1}", "{\"a\":2}"])
        XCTAssertEqual(q.count, 2)
        // Sonraki append yarım parçaya yapışmamalı.
        q.append("{\"a\":4}")
        let q2 = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        XCTAssertEqual(q2.peek(10), ["{\"a\":1}", "{\"a\":2}", "{\"a\":4}"])
    }

    func testDizinSilinirseCokmezVeBellekteCalisir() throws {
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        q.append("{\"a\":1}")
        try FileManager.default.removeItem(at: dir)
        q.append("{\"a\":2}")
        XCTAssertEqual(q.peek(10), ["{\"a\":1}", "{\"a\":2}"])
        // Dizin yeniden kurulur ve bellekteki tamamı diske yazılır: yeniden açan görür.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let q2 = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        XCTAssertEqual(q2.peek(10), ["{\"a\":1}", "{\"a\":2}"])
        try FileManager.default.removeItem(at: dir)
        q2.removeFirst(1)
        XCTAssertEqual(q2.peek(10), ["{\"a\":2}"])
        XCTAssertEqual(q2.count, 1)
    }

    func testDizinOlusturulamazsaBellektedirVeCokmez() throws {
        // Dizin yolunun üst parçası düz dosya: oluşturma imkânsız.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cz-blocker-\(UUID().uuidString)")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let q = EventQueue(
            directory: blocker.appendingPathComponent("alt", isDirectory: true),
            maxEvents: 3, maxBytes: 1_000_000)
        for i in 1...5 { q.append("{\"i\":\(i)}") }
        XCTAssertEqual(q.peek(10), ["{\"i\":3}", "{\"i\":4}", "{\"i\":5}"])
        XCTAssertEqual(q.droppedCount, 2)
    }

    func testSatirAyraciIcerenMetinKuyrugaGirmez() throws {
        let q = EventQueue(directory: dir, maxEvents: 100, maxBytes: 1_000_000)
        q.append("{\"a\":1}")
        q.append("{\"a\":\n2}")
        q.append("{\"a\":3}\r")
        q.append("")
        XCTAssertEqual(q.peek(10), ["{\"a\":1}"])
    }

    /// Kuyruğu bir actor sahiplenir (Core'un yapacağı gibi); eşzamanlı çağıranlar sıraya girer.
    private actor Sahip {
        let q: EventQueue
        init(dir: URL) { q = EventQueue(directory: dir, maxEvents: 100_000, maxBytes: 100_000_000) }
        func ekle(_ i: Int) { q.append("{\"i\":\(i)}") }
        func say() -> Int { q.count }
        func benzersiz() -> Int { Set(q.peek(5000)).count }
    }

    func testActorSahipliEsZamanliAppendKayipVermez() async throws {
        let sahip = Sahip(dir: dir)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<2000 { g.addTask { await sahip.ekle(i) } }
        }
        let say = await sahip.say()
        let benzersiz = await sahip.benzersiz()
        XCTAssertEqual(say, 2000)
        XCTAssertEqual(benzersiz, 2000)
        XCTAssertEqual(try physicalLines().count, 2000)
    }

    func testTvOSPlatformu100EventVe5FlushEsigiVerir() throws {
        let tv = Platform.make(name: "tvos")
        XCTAssertEqual(tv.name, "tvos")
        XCTAssertEqual(tv.maxEvents, 100)
        XCTAssertEqual(tv.maxBytes, 5 * 1024 * 1024)
        XCTAssertEqual(tv.flushAt, 5)
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertTrue(tv.queueDirectory.path.hasPrefix(caches.path))

        let ios = Platform.make(name: "ios")
        XCTAssertEqual(ios.maxEvents, 1000)
        XCTAssertEqual(ios.maxBytes, 5 * 1024 * 1024)
        XCTAssertEqual(ios.flushAt, 30)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertTrue(ios.queueDirectory.path.hasPrefix(support.path))

        let mac = Platform.make(name: "macos")
        XCTAssertEqual(mac.maxEvents, 1000)
        XCTAssertEqual(mac.flushAt, 30)
        XCTAssertTrue(mac.queueDirectory.path.hasPrefix(support.path))
    }

    func testCurrentMacOSUzerindeMacosDer() {
        #if os(macOS)
        XCTAssertEqual(Platform.current.name, "macos")
        #endif
    }
}

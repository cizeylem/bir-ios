import XCTest
@testable import Cizeylem

final class GzipTests: XCTestCase {
    private func gz(_ s: String) throws -> Data {
        try XCTUnwrap(Gzip.compress(Data(s.utf8)))
    }

    private func le32(_ d: Data, at i: Int) -> UInt32 {
        let b = Array(d)
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// Sistemin kendi gunzip'i: kendi kodumuzla kendi kodumuzu doğrulamak yetmez.
    private func gunzip(_ data: Data) throws -> (out: Data, status: Int32) {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("cz-gz-\(UUID().uuidString).gz")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        // Çıktı boru tamponunu aşabilir; önce oku, sonra bekle.
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (out, p.terminationStatus)
    }

    func testUretilenVeriGzipBasligiylaBaslar() throws {
        let d = try gz("{\"a\":1}")
        XCTAssertEqual(Array(d.prefix(4)), [0x1f, 0x8b, 0x08, 0x00])
        // mtime sıfır: aynı gövde her seferinde aynı baytları üretsin.
        XCTAssertEqual(Array(d[4..<8]), [0, 0, 0, 0])
        XCTAssertEqual(d, try gz("{\"a\":1}"))
    }

    func testCRC32VeBoyutAlanlariDogru() throws {
        // "123456789" için CRC-32 sabit test vektörü: 0xCBF43926.
        let d = try gz("123456789")
        XCTAssertEqual(le32(d, at: d.count - 8), 0xCBF43926)
        XCTAssertEqual(le32(d, at: d.count - 4), 9)
        XCTAssertEqual(Array(d.suffix(8).prefix(4)), [0x26, 0x39, 0xF4, 0xCB], "little-endian")
        XCTAssertEqual(Array(d.suffix(4)), [9, 0, 0, 0], "boyut little-endian")
    }

    func testSistemGunzipAyniJSONuGeriVerir() throws {
        let json = "{\"sent_at\":1,\"events\":[{\"event\":\"x\",\"props\":{\"k\":\"v\"}}]}"
        let r = try gunzip(try gz(json))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(String(decoding: r.out, as: UTF8.self), json)
    }

    func testBosVeriCokmezVeAcilabilir() throws {
        let d = try XCTUnwrap(Gzip.compress(Data()))
        XCTAssertEqual(Array(d.prefix(3)), [0x1f, 0x8b, 0x08])
        XCTAssertEqual(le32(d, at: d.count - 8), 0, "boş verinin CRC-32'si 0")
        XCTAssertEqual(le32(d, at: d.count - 4), 0)
        let r = try gunzip(d)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.out.isEmpty)
    }

    func testBirBaytlikVeriAcilir() throws {
        let r = try gunzip(try XCTUnwrap(Gzip.compress(Data([0x41]))))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, Data([0x41]))
    }

    func testCokBuyukVeriAcilir() throws {
        // 3 MB, tekrarlanmayan baytlar da içerir (deflate'in saklı blok yoluna da düşsün).
        var big = Data(String(repeating: "{\"event\":\"tekrar\"}", count: 100_000).utf8)
        var x: UInt64 = 88172645463325252
        for _ in 0..<(1_200_000 / 8) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            withUnsafeBytes(of: x) { big.append(contentsOf: $0) }
        }
        XCTAssertGreaterThanOrEqual(big.count, 3_000_000)
        let d = try XCTUnwrap(Gzip.compress(big))
        XCTAssertEqual(le32(d, at: d.count - 4), UInt32(big.count))
        let r = try gunzip(d)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, big)
    }

    func testRastgeleVeriGunzipleAcilir() throws {
        // Sıkıştırılamayan veri sıkıştırılmışın "büyümesine" yol açar; hedef tampon yetmeli.
        var x: UInt64 = 1234567
        var rnd = Data()
        for _ in 0..<(300_000 / 8) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            withUnsafeBytes(of: x) { rnd.append(contentsOf: $0) }
        }
        let r = try gunzip(try XCTUnwrap(Gzip.compress(rnd)))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, rnd)
    }

    func testUTF8CokBaytliKarakterlerKorunur() throws {
        let json = "{\"ad\":\"İbrahim Şıpal ğüöç 日本語 🎉👨‍👩‍👧\"}"
        let r = try gunzip(try gz(json))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(String(decoding: r.out, as: UTF8.self), json)
        XCTAssertEqual(le32(try gz(json), at: try gz(json).count - 4), UInt32(json.utf8.count),
                       "boyut karakter değil bayt sayısıdır")
    }

    func testHedefTamponYetmezseNilDonerBosAkisYazmaz() {
        let rnd = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 3) })
        XCTAssertNil(Gzip.deflate(rnd, capacity: 8))
        XCTAssertNotNil(Gzip.deflate(rnd))
    }
}

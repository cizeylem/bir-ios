import XCTest
@testable import Cizeylem

final class DeviceIdStoreTests: XCTestCase {

    private var dir: URL!
    private var suite: String!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cz-did-\(id)", isDirectory: true)
        suite = "cz-test-\(id)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func platform(_ name: String = "ios") -> Platform {
        Platform(name: name, queueDirectory: dir, maxEvents: 1, maxBytes: 1, flushAt: 1)
    }

    private func store(
        _ name: String = "ios", vendor: String? = "h1", uuid: String = "ID-1",
        readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> DeviceIdStore {
        DeviceIdStore(platform: platform(name), vendorHash: vendor,
                      uuid: { uuid }, defaultsSuite: suite, readFile: readFile)
    }

    private var idFile: URL { dir.appendingPathComponent("device_id") }
    private var hashFile: URL { dir.appendingPathComponent("vendor_hash") }
    private func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    func testIlkCagriUUIDUretirVeYazar() {
        XCTAssertEqual(store().getOrCreate(), "ID-1")
        XCTAssertEqual(text(idFile), "ID-1")
        XCTAssertEqual(text(hashFile), "h1")
        XCTAssertEqual(store(uuid: "baska").read(), "ID-1")
    }

    func testIkinciCagriAyniIdDondurur() {
        XCTAssertEqual(store(uuid: "ID-1").getOrCreate(), "ID-1")
        XCTAssertEqual(store(uuid: "ID-2").getOrCreate(), "ID-1")
    }

    func testVeriKorumasiKapaliykenNilDonerVeDosyaYazilmaz() throws {
        let denied: @Sendable (URL) throws -> Data = { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        // Kilit hiç açılmamış, dosya diskte duruyor ama okunamıyor: üstüne yazılmamalı.
        _ = store().getOrCreate()
        XCTAssertNil(store(uuid: "ID-2", readFile: denied).getOrCreate())
        XCTAssertEqual(text(idFile), "ID-1")
        XCTAssertEqual(text(hashFile), "h1")
        // Dosya hiç yokken de dizin/dosya oluşmaz.
        try FileManager.default.removeItem(at: dir)
        XCTAssertNil(store(readFile: denied).getOrCreate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testPOSIXEPERMAltHatasiDaKorumaKapaliSayilir() {
        let wrapped: @Sendable (URL) throws -> Data = { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        }
        XCTAssertNil(store(readFile: wrapped).getOrCreate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testDosyaYokHatasiKorumaKapaliSayilmaz() {
        let missing: @Sendable (URL) throws -> Data = { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }
        XCTAssertEqual(store(readFile: missing).getOrCreate(), "ID-1")
    }

    func testReadHicbirSeyOlusturmaz() {
        XCTAssertNil(store().read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "salt-okuma dizin yaratmamalı")
        XCTAssertNil(store("tvos").read())
        XCTAssertNil(UserDefaults(suiteName: suite)?.string(forKey: "cz_device_id"))
    }

    func testYazilamayanKimlikDondurulmez() throws {
        // Dizin yerine dosya konmuş: yazım başarısız; id döndürülürse bir sonraki çağrıda başkası çıkardı.
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir)
        XCTAssertNil(store().getOrCreate())
    }

    func testIDFVDegistiyseYeniIdUretilir() {
        XCTAssertEqual(store(vendor: "h1", uuid: "ID-1").getOrCreate(), "ID-1")
        XCTAssertEqual(store(vendor: "h2", uuid: "ID-2").getOrCreate(), "ID-2")
        XCTAssertEqual(text(idFile), "ID-2")
        XCTAssertEqual(text(hashFile), "h2")
        XCTAssertEqual(store(vendor: "h2", uuid: "ID-3").getOrCreate(), "ID-2")
    }

    func testIDFVNilIseKontrolAtlanirVeIdKorunur() {
        _ = store(vendor: "h1", uuid: "ID-1").getOrCreate()
        XCTAssertEqual(store(vendor: nil, uuid: "ID-2").getOrCreate(), "ID-1")
        XCTAssertEqual(text(hashFile), "h1", "nil açılış kayıtlı özeti silmemeli")
        // Kimlik üretimi IDFV'yi beklemez; hash sonradan bağlanır, id değişmez.
        try? FileManager.default.removeItem(at: dir)
        XCTAssertEqual(store(vendor: nil, uuid: "ID-A").getOrCreate(), "ID-A")
        XCTAssertNil(text(hashFile))
        XCTAssertEqual(store(vendor: "h9", uuid: "ID-B").getOrCreate(), "ID-A")
        XCTAssertEqual(text(hashFile), "h9")
    }

    func testDosyaIsExcludedFromBackupIsaretliyazilir() throws {
        _ = store().getOrCreate()
        for f in [idFile, hashFile] {
            let v = try f.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(v.isExcludedFromBackup, true, f.lastPathComponent)
        }
    }

    func testTvOSUserDefaultsKullanir() {
        XCTAssertEqual(store("tvos").getOrCreate(), "ID-1")
        let d = UserDefaults(suiteName: suite)
        XCTAssertEqual(d?.string(forKey: "cz_device_id"), "ID-1")
        XCTAssertEqual(d?.string(forKey: "cz_vendor_hash"), "h1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(store("tvos", uuid: "x").getOrCreate(), "ID-1")
        XCTAssertEqual(store("tvos", vendor: "h2", uuid: "ID-2").getOrCreate(), "ID-2")
    }

    func testBilinmeyenOkumaHatasiKorumaKapaliGibiDavranir() {
        // Gerçek kilit hata kodu cihazda doğrulanmadı: "dosya yok" dışındaki her hata fail-closed olmalı.
        let errors: [NSError] = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError),
            NSError(domain: "baska.alan", code: 42),
        ]
        for e in errors {
            _ = store().getOrCreate()
            XCTAssertNil(store(uuid: "ID-2", readFile: { _ in throw e }).getOrCreate(), "\(e)")
            XCTAssertEqual(text(idFile), "ID-1", "\(e): mevcut kimlik ezilmemeli")
            XCTAssertEqual(text(hashFile), "h1", "\(e)")
            try? FileManager.default.removeItem(at: dir)
            XCTAssertNil(store(readFile: { _ in throw e }).getOrCreate())
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "\(e): hiçbir şey yazılmamalı")
        }
    }

    func testDosyaYokHatalariAbsentSayilir() {
        let errors: [NSError] = [
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))]),
        ]
        for e in errors {
            try? FileManager.default.removeItem(at: dir)
            XCTAssertEqual(store(readFile: { _ in throw e }).getOrCreate(), "ID-1", "\(e)")
        }
    }

    func testHashYazilamazsaUyusmazlikdaKimlikDondurulmez() throws {
        _ = store(vendor: "h1", uuid: "ID-1").getOrCreate()
        // Okuma kayıtlı "h1"i görür, ama hash dosyasının yerinde dizin var: yazım kalıcı olarak başarısız.
        try FileManager.default.removeItem(at: hashFile)
        try FileManager.default.createDirectory(at: hashFile, withIntermediateDirectories: false)
        let hashFileURL = hashFile
        let reader: @Sendable (URL) throws -> Data = { url in
            url == hashFileURL ? Data("h1".utf8) : try Data(contentsOf: url)
        }
        XCTAssertNil(store(vendor: "h2", uuid: "ID-2", readFile: reader).getOrCreate())
    }

    func testTvOSReadVeKorumasizYoldaHicbirSeyYazilmaz() {
        let s = store("tvos")
        XCTAssertNil(s.read())
        let d = UserDefaults(suiteName: suite)
        XCTAssertNil(d?.string(forKey: "cz_device_id"))
        XCTAssertNil(d?.string(forKey: "cz_vendor_hash"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testSHA256OzetiBilinenDegeriVerir() {
        XCTAssertEqual(VendorId.hash(of: "abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

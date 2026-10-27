import XCTest
import SQLite3
@testable import Cizeylem

final class AmplitudeTakeoverTests: XCTestCase {

    private var root: URL!
    private var library: URL!
    private var ownDir: URL!
    private var apiKey: String!
    private var ownSuite: String!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cz-amp-\(id)", isDirectory: true)
        library = root.appendingPathComponent("Library", isDirectory: true)
        ownDir = root.appendingPathComponent("Own", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        apiKey = "key-\(id)"
        ownSuite = "cz-test-\(id)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: swiftSuite())
        UserDefaults().removePersistentDomain(forName: ownSuite)
    }

    // MARK: - Yardımcılar

    private func swiftSuite(instance: String = "$default_instance") -> String {
        "com.amplitude.storage.amplitude-swift-storage-\(apiKey!)-\(instance)"
    }

    private func putSwiftDeviceId(_ id: String, instance: String = "$default_instance") {
        UserDefaults(suiteName: swiftSuite(instance: instance))!.set(id, forKey: "device_id")
    }

    private func ownStore() -> DeviceIdStore {
        let p = Platform(name: "ios", queueDirectory: ownDir, maxEvents: 1, maxBytes: 1, flushAt: 1)
        return DeviceIdStore(platform: p, vendorHash: nil, uuid: { "own-uuid" }, defaultsSuite: ownSuite)
    }

    private func find(configured: String? = nil, instance: String = "") -> Takeover? {
        AmplitudeTakeover.find(apiKey: apiKey, configured: configured, instance: instance,
                               ownStore: ownStore(), libraryDirectory: library)
    }

    @discardableResult
    private func makeDB(name: String = "com.amplitude.database", deviceId: String? = nil, optOut: Int? = nil) throws -> URL {
        let url = library.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
        CREATE TABLE store (key TEXT PRIMARY KEY NOT NULL, value TEXT);
        CREATE TABLE long_store (key TEXT PRIMARY KEY NOT NULL, value INTEGER);
        """
        if let deviceId { sql += "INSERT INTO store VALUES ('device_id', '\(deviceId)');" }
        if let optOut { sql += "INSERT INTO long_store VALUES ('opt_out', \(optOut));" }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }

    private func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: - Brief testleri

    func testConfiguredDeviceIdHerSeyinOnundeGelir() throws {
        putSwiftDeviceId("swift-id")
        try makeDB(deviceId: "sql-id")
        _ = ownStore().getOrCreate()
        let t = find(configured: "benim-id")
        XCTAssertEqual(t?.deviceId, "benim-id")
        XCTAssertEqual(t?.source, "configured")
        XCTAssertEqual(t?.optOut, false)
    }

    func testAmplitudeSwiftSuiteindenOkunur() {
        putSwiftDeviceId("swift-id")
        let t = find()
        XCTAssertEqual(t?.deviceId, "swift-id")
        XCTAssertEqual(t?.source, "amplitude-swift")
        XCTAssertEqual(t?.optOut, false)
    }

    func testEskiSQLiteStoreTablosundanOkunur() throws {
        try makeDB(deviceId: "sql-id")
        let t = find()
        XCTAssertEqual(t?.deviceId, "sql-id")
        XCTAssertEqual(t?.source, "amplitude-sqlite")
    }

    func testGecersizDegerElenirVeSonrakiKaynagaGecilir() throws {
        putSwiftDeviceId("E3F5536A141811DB40EFD6400F1D0A4E")
        try makeDB(deviceId: "sql-id")
        XCTAssertEqual(find()?.deviceId, "sql-id")
        XCTAssertEqual(find()?.source, "amplitude-sqlite")
    }

    func testGecersizDegerListesiBuyukKucukHarfDuyarsiz() throws {
        let invalid = ["", "e3f5536a141811db40efd6400f1d0a4e", "04BAB7EE75B9A58D39B8DC54E8851084",
                       "00000000-0000-0000-0000-000000000000", "02:00:00:00:00:00", "020000000000"]
        for bad in invalid {
            putSwiftDeviceId(bad)
            XCTAssertNil(find(), "elenmeli: \(bad)")
        }
        try makeDB(deviceId: "02:00:00:00:00:00")
        XCTAssertNil(find())
    }

    func testRVeSEkiliIdGecerlidir() {
        putSwiftDeviceId("ABCDEFR")
        XCTAssertEqual(find()?.deviceId, "ABCDEFR")
        putSwiftDeviceId("ABCDEFS")
        XCTAssertEqual(find()?.deviceId, "ABCDEFS")
    }

    func testOkunanAmplitudeKaydiDegismedenKalir() throws {
        putSwiftDeviceId("swift-id")
        let db = try makeDB(deviceId: "sql-id", optOut: 1)
        let before = try Data(contentsOf: db)
        let names = listing(library)
        _ = find()
        UserDefaults().removePersistentDomain(forName: swiftSuite())
        _ = find()
        XCTAssertEqual(try Data(contentsOf: db), before)
        XCTAssertEqual(listing(library), names, "yan dosya oluşmamalı")
        // Swift suite'i de değişmedi.
        putSwiftDeviceId("swift-id")
        _ = find()
        XCTAssertEqual(UserDefaults(suiteName: swiftSuite())!.dictionaryRepresentation()["device_id"] as? String, "swift-id")
        XCTAssertNil(UserDefaults(suiteName: swiftSuite())!.object(forKey: "opt_out"))
    }

    func testOptOutKorunur() throws {
        try makeDB(deviceId: "sql-id", optOut: 1)
        XCTAssertEqual(find()?.optOut, true)
        try FileManager.default.removeItem(at: library.appendingPathComponent("com.amplitude.database"))
        try makeDB(deviceId: "sql-id", optOut: 0)
        XCTAssertEqual(find()?.optOut, false)
    }

    func testOptOutYoksaFalse() throws {
        try makeDB(deviceId: "sql-id")
        XCTAssertEqual(find()?.optOut, false)
        putSwiftDeviceId("swift-id")
        XCTAssertEqual(find()?.optOut, false, "SQLite kaydı hiç yokken Swift kaynağı false")
    }

    /// Kullanıcı eski ObjC SDK'sında çıkış yapmış, sonra Swift'e geçilmiş: çıkış bilgisi kimlik
    /// zincirinden bağımsız taşınmalı.
    func testOptOutKimlikKaynagindanBagimsizOkunur() throws {
        try makeDB(deviceId: "sql-id", optOut: 1)
        putSwiftDeviceId("swift-id")
        let swift = find()
        XCTAssertEqual(swift?.source, "amplitude-swift")
        XCTAssertEqual(swift?.optOut, true)
        let configured = find(configured: "benim-id")
        XCTAssertEqual(configured?.source, "configured")
        XCTAssertEqual(configured?.optOut, true)
    }

    func testOptOutSQLitedeKimlikGecersizkenDeSwiftKimligiyleTasinir() throws {
        try makeDB(deviceId: "020000000000", optOut: 1)
        putSwiftDeviceId("swift-id")
        XCTAssertEqual(find()?.optOut, true)
    }

    func testOptOutSQLitedeKimlikSatiriYokkenDeTasinir() throws {
        try makeDB(deviceId: nil, optOut: 1)
        putSwiftDeviceId("swift-id")
        XCTAssertEqual(find()?.optOut, true)
    }

    func testOptOutBozukVeritabaniFalseVerir() throws {
        try Data("not a database".utf8).write(to: library.appendingPathComponent("com.amplitude.database"))
        putSwiftDeviceId("swift-id")
        XCTAssertEqual(find()?.optOut, false)
    }

    func testHicbirKaynakYoksaNilDoner() {
        XCTAssertNil(find())
    }

    // MARK: - Sıra ve instance

    func testKendiDepomuzdaIdVarsaDevralmaYok() throws {
        putSwiftDeviceId("swift-id")
        try makeDB(deviceId: "sql-id")
        XCTAssertEqual(ownStore().getOrCreate(), "own-uuid")
        XCTAssertNil(find(), "kendi depo kazanır; migrated_from tekrar tetiklenmemeli")
    }

    func testSwiftSuiteSQLiteinOnundeGelir() throws {
        putSwiftDeviceId("swift-id")
        try makeDB(deviceId: "sql-id")
        XCTAssertEqual(find()?.deviceId, "swift-id")
    }

    func testBosInstanceVarsayilanaNormalizeOlur() {
        putSwiftDeviceId("swift-id")
        XCTAssertEqual(find(instance: "")?.deviceId, "swift-id")
        XCTAssertEqual(find(instance: "$default_instance")?.deviceId, "swift-id")
    }

    func testNamedInstanceSuiteKucukHarfeCevrilmez() {
        putSwiftDeviceId("swift-named", instance: "MyInst")
        XCTAssertEqual(find(instance: "MyInst")?.deviceId, "swift-named")
        // Not: macOS'ta tercih dosyaları büyük/küçük harf duyarsız olabilir; "myinst" için nil
        // doğrulaması platformdan bağımsız olmadığından yapılmaz.
        UserDefaults().removePersistentDomain(forName: swiftSuite(instance: "MyInst"))
    }

    func testNamedInstanceSQLiteDosyasiKucukHarfSonEkli() throws {
        try makeDB(name: "com.amplitude.database_myinst", deviceId: "sql-named")
        try makeDB(deviceId: "default-db")
        XCTAssertEqual(find(instance: "MyInst")?.deviceId, "sql-named")
    }

    func testIsimNormalizasyonu() {
        XCTAssertEqual(AmplitudeTakeover.swiftSuiteName(apiKey: "K", instance: ""),
                       "com.amplitude.storage.amplitude-swift-storage-K-$default_instance")
        XCTAssertEqual(AmplitudeTakeover.swiftSuiteName(apiKey: "K", instance: "MyInst"),
                       "com.amplitude.storage.amplitude-swift-storage-K-MyInst")
        XCTAssertEqual(AmplitudeTakeover.legacyDatabaseName(instance: ""), "com.amplitude.database")
        XCTAssertEqual(AmplitudeTakeover.legacyDatabaseName(instance: "$default_instance"), "com.amplitude.database")
        XCTAssertEqual(AmplitudeTakeover.legacyDatabaseName(instance: "MyInst"), "com.amplitude.database_myinst")
    }

    /// Gerçek sıcak journal: yarım kalmış işlem. Yazılabilir açış bunu geri sarıp journal'ı silerdi;
    /// salt okunur açış dokunmamalı (READWRITE mutasyonunu yakalar).
    func testSicakJournalliVeritabaniDegismezVeJournalSilinmez() throws {
        let src = root.appendingPathComponent("src.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(src.path, &db), SQLITE_OK)
        let setup = """
        CREATE TABLE store (key TEXT PRIMARY KEY NOT NULL, value TEXT);
        CREATE TABLE long_store (key TEXT PRIMARY KEY NOT NULL, value INTEGER);
        CREATE TABLE events (id INTEGER PRIMARY KEY, event TEXT);
        INSERT INTO store VALUES ('device_id', 'sql-id');
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA cache_size=1; PRAGMA cache_spill=1;", nil, nil, nil)
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        for _ in 0..<3000 {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO events (event) VALUES (hex(randomblob(2000)));", nil, nil, nil), SQLITE_OK)
        }
        let dst = library.appendingPathComponent("com.amplitude.database")
        let jr = library.appendingPathComponent("com.amplitude.database-journal")
        try FileManager.default.copyItem(at: src, to: dst)
        try FileManager.default.copyItem(at: root.appendingPathComponent("src.db-journal"), to: jr)
        sqlite3_close(db)
        let dbBefore = try Data(contentsOf: dst)
        let jrBefore = try Data(contentsOf: jr)
        XCTAssertGreaterThan(jrBefore.count, 0)
        _ = find()
        XCTAssertEqual(try Data(contentsOf: dst), dbBefore)
        XCTAssertEqual(try Data(contentsOf: jr), jrBefore, "sıcak journal silinmemeli/değişmemeli")
        XCTAssertEqual(listing(library), ["com.amplitude.database", "com.amplitude.database-journal"])
    }

    func testSwiftSuiteteBosDeger() {
        UserDefaults(suiteName: swiftSuite())!.set(42, forKey: "device_id")
        XCTAssertNil(find(), "String olmayan değer geçersiz")
    }

    func testBosConfiguredYokSayilir() {
        putSwiftDeviceId("swift-id")
        XCTAssertEqual(find(configured: "")?.source, "amplitude-swift")
        XCTAssertEqual(find(configured: "  ")?.source, "amplitude-swift")
    }

    // MARK: - Salt okuma ve bozuk veritabanı

    func testBozukVeritabaniAtlanirVeBaytlarDegismez() throws {
        let url = library.appendingPathComponent("com.amplitude.database")
        let junk = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try junk.write(to: url)
        let names = listing(library)
        XCTAssertNil(find())
        XCTAssertEqual(try Data(contentsOf: url), junk)
        XCTAssertEqual(listing(library), names, "-wal/-shm/-journal oluşmamalı")
    }

    func testYarimBozukSQLiteBasligiDaDegismez() throws {
        let good = try makeDB(deviceId: "sql-id", optOut: 1)
        var data = try Data(contentsOf: good)
        data.replaceSubrange(100..<min(data.count, 300), with: Data(repeating: 0xFF, count: min(data.count, 300) - 100))
        try data.write(to: good)
        let names = listing(library)
        _ = find()
        XCTAssertEqual(try Data(contentsOf: good), data)
        XCTAssertEqual(listing(library), names)
    }

    func testBozukSQLiteyeRağmenSwiftSuiteCalisir() throws {
        try Data("not a database".utf8).write(to: library.appendingPathComponent("com.amplitude.database"))
        putSwiftDeviceId("swift-id")
        XCTAssertEqual(find()?.deviceId, "swift-id")
    }

    func testStoreTablosuYoksaNilDoner() throws {
        let url = library.appendingPathComponent("com.amplitude.database")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE other (a TEXT);", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertNil(find())
    }

    func testGecerliVeritabaniYanDosyaOlusturmaz() throws {
        let db = try makeDB(deviceId: "sql-id", optOut: 1)
        let before = try Data(contentsOf: db)
        let names = listing(library)
        XCTAssertEqual(find()?.deviceId, "sql-id")
        XCTAssertEqual(listing(library), names)
        XCTAssertEqual(try Data(contentsOf: db), before)
    }

    func testDosyaYokkenHicbirSeyOlusturulmaz() {
        let missing = root.appendingPathComponent("YokKutuphane", isDirectory: true)
        let t = AmplitudeTakeover.find(apiKey: apiKey, configured: nil, instance: "",
                                       ownStore: ownStore(), libraryDirectory: missing)
        XCTAssertNil(t)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownDir.path))
        // Suite anahtarı da yaratılmadı.
        XCTAssertNil(UserDefaults(suiteName: swiftSuite())!.object(forKey: "device_id"))
        #if os(macOS)
        // `homeDirectoryForCurrentUser` yalnız macOS SDK'sında var.
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(swiftSuite()).plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        #endif
    }

    func testGenelAcikGirisNoktasiCalisir() {
        // Gerçek Platform/dizin: hiçbir şey bulunamaz ama çökmemeli ve configured çalışmalı.
        XCTAssertEqual(AmplitudeTakeover.find(apiKey: apiKey, configured: "x")?.source, "configured")
    }

    // MARK: - Görev 17: anahtarsız arama

    private func findKeyless(_ key: String?) -> Takeover? {
        AmplitudeTakeover.find(apiKey: key, configured: nil, instance: "",
                               ownStore: ownStore(), libraryDirectory: library)
    }

    func testAnahtarNilkenSwiftSuiteTaranmazAmaSQLiteCalisir() throws {
        // Anlamsız ad (anahtarsız kurulan suite) dolu olsa bile okunmamalı.
        let bogus = "com.amplitude.storage.amplitude-swift-storage--$default_instance"
        UserDefaults(suiteName: bogus)!.set("bogus-id", forKey: "device_id")
        defer { UserDefaults().removePersistentDomain(forName: bogus) }
        XCTAssertNil(findKeyless(nil), "anahtar yokken suite taranmaz")
        XCTAssertNil(findKeyless(""))
        XCTAssertNil(findKeyless("   "))
        try makeDB(deviceId: "sql-id")
        let t = findKeyless(nil)
        XCTAssertEqual(t?.deviceId, "sql-id")
        XCTAssertEqual(t?.source, "amplitude-sqlite")
        XCTAssertEqual(findKeyless("")?.source, "amplitude-sqlite")
    }
}

import XCTest
@testable import Cizeylem

final class ConsentStoreTests: XCTestCase {

    private var dir: URL!
    private var suite: String!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cz-consent-\(id)", isDirectory: true)
        suite = "cz-consent-test-\(id)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func platform(_ name: String) -> Platform {
        Platform(name: name, queueDirectory: dir, maxEvents: 1, maxBytes: 1, flushAt: 1)
    }

    private func store(
        _ name: String = "ios",
        readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> ConsentStore {
        ConsentStore(platform: platform(name), defaultsSuite: suite, readFile: readFile)
    }

    private var file: URL { dir.appendingPathComponent("consent") }
    private let off = Consent()
    private let all = Consent(analytics: true, attribution: true, adSharing: true)

    private func put(_ raw: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: file)
    }

    private func putBytes(_ bytes: [UInt8]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(bytes).write(to: file)
    }

    /// Dizindeki her şeyin yol + bayt görüntüsü; "iz yok" iddiası bununla bayt bayt karşılaştırılır.
    private func snapshot() -> [String: Data] {
        var out: [String: Data] = [:]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
        for case let u as URL in e {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            out[u.path] = isDir ? Data("<dir>".utf8) : (try? Data(contentsOf: u)) ?? Data()
        }
        return out
    }

    // MARK: - Plan testleri

    func testVarsayilanUcAnahtarDaKapali() {
        XCTAssertEqual(Consent(), off)
        XCTAssertFalse(Consent().analytics)
        XCTAssertFalse(Consent().attribution)
        XCTAssertFalse(Consent().adSharing)
        // Hiçbir şey yazılmamış depo da kapalı okunur.
        XCTAssertEqual(store().read(), off)
        XCTAssertEqual(store("tvos").read(), off)
    }

    func testYazilanRizaSonrakiOkumadaKorunur() {
        let c = Consent(analytics: true, attribution: false, adSharing: true)
        XCTAssertTrue(store().write(c))
        XCTAssertEqual(store().read(), c)
        XCTAssertEqual(store().read(), c)
        // Her alan ayrı ayrı doğru yerde kalıyor (alan karışması).
        for k in 0..<8 {
            let v = Consent(analytics: k & 1 != 0, attribution: k & 2 != 0, adSharing: k & 4 != 0)
            XCTAssertTrue(store().write(v))
            XCTAssertEqual(store().read(), v, "k=\(k)")
        }
    }

    func testYazimDosyayaAtomikYapilir() throws {
        XCTAssertTrue(store().write(all))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["consent"], "geçici/yan dosya kalmamalı")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "analytics=true\nattribution=true\nadSharing=true\n")
    }

    func testBozukRizaKaydiHepsiKapaliOkunur() throws {
        let bozuklar: [String] = [
            "",
            "   \n",
            "garbage",
            "{\"analytics\":true,\"attribution\":true,\"adSharing\":true}",   // başka biçim
            "analytics=true",                                                  // eksik
            "analytics=true\nattribution=true",                                // eksik
            "analytics=true\n",                                                // eksik, newline'lı
            "adSharing=true\n",
            "analytics=true\nattribution=true\n",
            "attribution=true\nadSharing=true\n",
            "analytics=true\nanalytics=true\nattribution=true\n",            // yinelenen + eksik
            "analytics=true\nattribution=true\nadSharing=true\nextra=true\n",  // fazla
            "analytics=true\nattribution=true\nadSharing=true\nanalytics=true\n", // yinelenen, aynı değer
            "analytics=false\nattribution=true\nadSharing=true\nanalytics=true\n", // yinelenen, çelişen
            "analytics=true\nanalytics=true\nanalytics=true\n",                // üç anahtar yerine tek anahtar x3
            "analytics=yes\nattribution=true\nadSharing=true\n",
            "analytics=TRUE\nattribution=true\nadSharing=true\n",
            "analytics=1\nattribution=1\nadSharing=1\n",
            "analytics=\nattribution=true\nadSharing=true\n",
            "analytics = true\nattribution=true\nadSharing=true\n",
            "analytics=true=true\nattribution=true\nadSharing=true\n",   // fazladan eşittir
            "analytics=true=\nattribution=true\nadSharing=true\n",
            "analytics==true\nattribution=true\nadSharing=true\n",
            "Analytics=true\nattribution=true\nadSharing=true\n",
            "analytics=true\n\nattribution=true\nadSharing=true\n",           // boş satır
            "analytics=true\nattribution=true\nadSharing=true\n\n",            // fazladan boş satır
            "analytics=true\nattribution=true\nadSharing\n",
            "analytics=true;attribution=true;adSharing=true",
            "analytics=true\r\nattribution=true\r\nadSharing=true\r\n",
        ]
        for raw in bozuklar {
            try put(raw)
            XCTAssertEqual(store().read(), off, "kapalı okunmalı: \(raw.debugDescription)")
        }
    }

    func testCopBaytVeGecersizUTF8HepsiKapaliOkunur() throws {
        let cop: [[UInt8]] = [
            [0xFF, 0xFE, 0x00, 0x01],
            [0x00, 0x00, 0x00],
            Array("analytics=true\nattribution=true\nadSharing=true\n".utf8) + [0xC3],   // yarım UTF-8
            [0xEF, 0xBB, 0xBF] + Array("analytics=true\nattribution=true\nadSharing=true\n".utf8), // BOM
            Array("analytics=true\nattribution=true\nadSharing=true\n".utf8) + [0x00],
            Array(repeating: 0x41, count: 100_000),
        ]
        for b in cop {
            try putBytes(b)
            XCTAssertEqual(store().read(), off)
        }
    }

    func testYinelenenAnahtarKoruması() throws {
        // Son geçerli değer kazanmamalı: yinelenen kayıtta "analytics" asla açık okunmaz.
        try put("analytics=true\nattribution=false\nadSharing=false\nattribution=false\n")
        XCTAssertEqual(store().read(), off)
        try put("analytics=true\nattribution=true\nadSharing=true\nanalytics=true\n")
        XCTAssertEqual(store().read().analytics, false)
        XCTAssertFalse(store().allowsWrite())
    }

    func testOkunamayanDosyaKapaliOkunurVeFirlatmaz() throws {
        XCTAssertTrue(store().write(all))
        let denied: @Sendable (URL) throws -> Data = { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        XCTAssertEqual(store(readFile: denied).read(), off)
        let weird: @Sendable (URL) throws -> Data = { _ in
            throw NSError(domain: "x", code: 42)
        }
        XCTAssertEqual(store(readFile: weird).read(), off)
        XCTAssertFalse(store(readFile: denied).allowsWrite())
        // Dosyanın yerinde dizin var: okuma hatası da kapalı.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertEqual(store().read(), off)
    }

    func testBaskaKayitBozulupDuzeltilinceYenidenOkunur() throws {
        // Bozuk kayıt "son geçerli değer" olarak yedeklenmez: bozulunca kapalı, düzelince yeni değer.
        XCTAssertTrue(store().write(all))
        try put("bozuk")
        XCTAssertEqual(store().read(), off)
        try put("analytics=true\nattribution=false\nadSharing=false\n")
        XCTAssertEqual(store().read(), Consent(analytics: true))
    }

    // MARK: - Kapılar

    func testRizasizDurumdaKapiYazmayaIzinVermez() {
        XCTAssertFalse(store().allowsWrite())
        XCTAssertFalse(store("tvos").allowsWrite())
        XCTAssertFalse(Consent().allowsWrite)
    }

    func testKapiOkumadaDepodakiGuncelDegeriGorur() {
        let s = store()
        XCTAssertFalse(s.allowsWrite())
        XCTAssertTrue(s.write(Consent(analytics: true)))
        XCTAssertTrue(s.allowsWrite())
        XCTAssertTrue(s.write(off))
        XCTAssertFalse(s.allowsWrite())
        // Başka bir örnek (başka süreç gibi) araya girip geri alırsa bayat okuma olmaz.
        XCTAssertTrue(s.write(Consent(analytics: true)))
        XCTAssertTrue(store().write(off))
        XCTAssertFalse(s.allowsWrite())
    }

    func testOnbellekYokDisaridanSilinenDosyaHemenKapatir() throws {
        XCTAssertTrue(store().write(all))
        let s = store()
        XCTAssertTrue(s.read().analytics)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(s.read(), off)
    }

    /// Sekiz kombinasyonun (2³) her biri için tüm kapılar; tablo SPEC §5'in katmanlı okunuşudur.
    func testSekizKombinasyonunHerBiriIcinKapilar() {
        for k in 0..<8 {
            let a = k & 1 != 0, t = k & 2 != 0, s = k & 4 != 0
            let c = Consent(analytics: a, attribution: t, adSharing: s)
            let tag = "analytics=\(a) attribution=\(t) adSharing=\(s)"
            XCTAssertEqual(c.allowsWrite, a, tag)
            XCTAssertEqual(c.allowsIdentifiedAttribution, a && t, tag)
            XCTAssertEqual(c.allowsAttStatus, a && t && s, tag)
            XCTAssertEqual(c.allowsDeviceId(on: .identified), a && t, tag)
            XCTAssertEqual(c.allowsIdfa(on: .identified), a && t && s, tag)
            // Kimliksiz uç: hiçbir kombinasyonda kimlik ya da reklam kimliği yok.
            XCTAssertFalse(c.allowsDeviceId(on: .anonymous), tag)
            XCTAssertFalse(c.allowsIdfa(on: .anonymous), tag)
        }
    }

    func testYalnizAdSharingHicbirUcaIdfaAcmaz() {
        let c = Consent(analytics: false, attribution: false, adSharing: true)
        XCTAssertFalse(c.allowsIdfa(on: .identified))
        XCTAssertFalse(c.allowsIdfa(on: .anonymous))
        XCTAssertFalse(c.allowsWrite)
        XCTAssertFalse(c.allowsIdentifiedAttribution)
        XCTAssertFalse(c.allowsAttStatus)
        XCTAssertFalse(c.allowsDeviceId(on: .identified))
        // adSharing + analytics (attribution yok): yine kimlikli yol kapalı, IDFA yok.
        let d = Consent(analytics: true, attribution: false, adSharing: true)
        XCTAssertFalse(d.allowsIdfa(on: .identified))
        XCTAssertFalse(d.allowsIdfa(on: .anonymous))
        // adSharing + attribution (analytics yok): kalıcı kimlik anahtarı kapalı.
        let e = Consent(analytics: false, attribution: true, adSharing: true)
        XCTAssertFalse(e.allowsIdfa(on: .identified))
        XCTAssertFalse(e.allowsIdfa(on: .anonymous))
        XCTAssertFalse(e.allowsDeviceId(on: .identified))
    }

    func testAnalyticsYokkenAttributionVerilseDeKimliksizGider() {
        let c = Consent(analytics: false, attribution: true, adSharing: false)
        XCTAssertFalse(c.allowsDeviceId(on: .identified))
        XCTAssertFalse(c.allowsIdentifiedAttribution)
        XCTAssertFalse(c.allowsWrite)
    }

    func testTumUcaGecenIdfaYalnizUcluRizadaVeKimlikliYoldaAcilir() {
        XCTAssertTrue(all.allowsIdfa(on: .identified))
        XCTAssertFalse(all.allowsIdfa(on: .anonymous))
        XCTAssertTrue(all.allowsDeviceId(on: .identified))
    }

    // MARK: - İz bırakmama

    func testReadHicIzBirakmazDizinYokken() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        _ = store().read()
        _ = store().allowsWrite()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(UserDefaults(suiteName: suite)?.object(forKey: ConsentStore.defaultsKey))
    }

    func testReadDizinVarkenBaytBaytDegistirmez() throws {
        for raw in ["", "bozuk", "analytics=true\nattribution=true\nadSharing=true\n"] {
            try? FileManager.default.removeItem(at: dir)
            try put(raw)
            try Data("dokunma".utf8).write(to: dir.appendingPathComponent("baska"))
            let before = snapshot()
            for _ in 0..<3 { _ = store().read(); _ = store().allowsWrite() }
            XCTAssertEqual(snapshot(), before, raw)
        }
    }

    func testReadBozukKayitTemizlemezVeDuzeltmez() throws {
        try put("bozuk")
        let before = snapshot()
        _ = store().read()
        XCTAssertEqual(snapshot(), before)
    }

    func testTumKapaliYazmakDosyayiSilerIzBirakmaz() throws {
        XCTAssertTrue(store().write(all))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store().write(off))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store().read(), off)
        // Hiç yokken tümü-kapalı yazmak dizin de yaratmaz.
        try FileManager.default.removeItem(at: dir)
        XCTAssertTrue(store().write(off))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testYazimBasarisizsaFalseDonerVeKapaliOkunur() throws {
        // queueDirectory yerinde dosya: yazım başarısız olur, sonuç false ve okuma kapalı.
        XCTAssertTrue(store().write(all))
        try FileManager.default.removeItem(at: dir)
        try Data("dosya".utf8).write(to: dir)   // queueDirectory bir dosya
        XCTAssertFalse(store().write(Consent(analytics: true)))
        XCTAssertEqual(store().read(), off)
        try FileManager.default.removeItem(at: dir)
    }

    func testYazimBasarisizkenEskiKayitYolundaKalmaz() throws {
        // `consent` yolunda boş olmayan bir dizin: atomik yazım yerine koyamaz. Başarısız yazımdan
        // sonra eski kaydın yolu temizlenmeli (geri alma yazılamadıysa eski "açık" kayıt geçerli kalmaz).
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file.appendingPathComponent("i"))
        XCTAssertFalse(store().write(Consent(analytics: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store().read(), off)
    }

    func testDosyaYedektenHaric() throws {
        XCTAssertTrue(store().write(all))
        let v = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(v.isExcludedFromBackup, true)
    }

    // MARK: - tvOS

    func testTvOSUserDefaultsKullanirDosyaYazmaz() {
        let c = Consent(analytics: true, attribution: true, adSharing: false)
        XCTAssertTrue(store("tvos").write(c))
        XCTAssertEqual(store("tvos").read(), c)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: ConsentStore.defaultsKey),
                       "analytics=true\nattribution=true\nadSharing=false\n")
    }

    func testTvOSBozukKayitHepsiKapali() {
        let d = UserDefaults(suiteName: suite)!
        for raw in ["", "x", "analytics=true", "analytics=true\nattribution=true\nadSharing=true\nanalytics=true\n"] {
            d.set(raw, forKey: ConsentStore.defaultsKey)
            XCTAssertEqual(store("tvos").read(), off, raw)
        }
        d.set(1, forKey: ConsentStore.defaultsKey)   // dize olmayan tür
        XCTAssertEqual(store("tvos").read(), off)
        d.set(true, forKey: ConsentStore.defaultsKey)
        XCTAssertEqual(store("tvos").read(), off)
    }

    func testTvOSReadHicIzBirakmaz() {
        _ = store("tvos").read()
        _ = store("tvos").allowsWrite()
        XCTAssertNil(UserDefaults(suiteName: suite)?.object(forKey: ConsentStore.defaultsKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testTvOSTumKapaliYazmakAnahtariSiler() {
        XCTAssertTrue(store("tvos").write(all))
        XCTAssertTrue(store("tvos").write(off))
        XCTAssertNil(UserDefaults(suiteName: suite)?.object(forKey: ConsentStore.defaultsKey))
    }

    func testTvOSOnbellekYok() {
        let s = store("tvos")
        XCTAssertTrue(s.write(Consent(analytics: true)))
        XCTAssertTrue(s.allowsWrite())
        UserDefaults(suiteName: suite)?.removeObject(forKey: ConsentStore.defaultsKey)
        XCTAssertFalse(s.allowsWrite())
    }

    func testIosVeTvosDepolariAyriDir() throws {
        XCTAssertTrue(store("tvos").write(all))
        XCTAssertEqual(store("ios").read(), off)
    }

    // MARK: - Genel API

    func testConsentGenelAPIVeSendableEquatable() {
        let c = Consent(analytics: true, attribution: false, adSharing: true)
        XCTAssertTrue(c.analytics); XCTAssertFalse(c.attribution); XCTAssertTrue(c.adSharing)
        XCTAssertNotEqual(c, Consent(analytics: true))
        let s: any Sendable = c
        _ = s
    }
}

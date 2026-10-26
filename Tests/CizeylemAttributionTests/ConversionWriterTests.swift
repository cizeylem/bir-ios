import XCTest
@testable import CizeylemAttribution
@testable import Cizeylem

/// Sahte SKAN/AAK yüzeyi: gerçek sistem API'sine hiç dokunmadan çağrıları kaydeder.
final class SurfaceLog: @unchecked Sendable {
    struct Call: Equatable { let fine: Int; let coarse: String; let lock: Bool }
    private let lock = NSLock()
    private var calls: [Call] = []
    let fetches = Counter()
    func record(_ c: Call) { lock.withLock { calls.append(c) } }
    var all: [Call] { lock.withLock { calls } }
}

final class ConversionWriterTests: XCTestCase {
    private let full = Consent(analytics: true, attribution: true, adSharing: true)
    private let url = URL(string: "https://cdn.example.com/schema.json")!

    private func schema(_ rules: [ConversionSchema.Rule], version: Int = 1) -> ConversionSchema {
        ConversionSchema(version: version, rules: rules)
    }

    private func rule(_ event: String, min: Int = 1, fine: Int, coarse: String = "low",
                      lock: Bool = false) -> ConversionSchema.Rule {
        ConversionSchema.Rule(event: event, min: min, fine: fine, coarse: coarse, lockWindow: lock)
    }

    private let goodJSON = Data("""
    {"version": 1, "rules": [{"event": "first_open", "min": 1, "fine": 5, "coarse": "medium", "lockWindow": true}]}
    """.utf8)

    private func env(_ log: SurfaceLog, data: Data?, supported: Bool? = true) -> ConversionWriter.Environment {
        let fetch: @Sendable (URL) async -> Data? = { _ in log.fetches.hit(); return data }
        let surface: @Sendable (Int, String, Bool) async -> Void = { f, c, l in
            log.record(.init(fine: f, coarse: c, lock: l))
        }
        if let supported {
            return ConversionWriter.Environment(fetch: fetch, surface: surface, supported: supported)
        }
        return ConversionWriter.Environment(fetch: fetch, surface: surface)
    }

    // MARK: Karar 1 — varsayılan kapalı

    /// Ayırt edici: fetch geçerli bir şema DÖNDÜRÜR, rıza tamdır, yüzey desteklidir. Yine de
    /// `start` hiçbir şeye dokunmuyorsa yazıcı gerçekten ayrı bir çağrıdır.
    func testVarsayilanOlarakYaziciKapali() async {
        let log = SurfaceLog()
        let probe = Counter()
        let signals = Attribution.Signals(token: { probe.hit(); return "tok" },
                                          attStatus: { "authorized" }, idfa: { nil })
        let task = Attribution.startTask(sink: RecordingSink(), consent: full, signals: signals,
                                         conversion: env(log, data: goodJSON))
        await task.value
        XCTAssertEqual(probe.count, 1, "start gerçekten koştu (test boş geçmesin)")
        XCTAssertEqual(log.fetches.count, 0, "start şema indirmemeli")
        XCTAssertTrue(log.all.isEmpty, "start SKAN/AAK'a dokunmamalı")
    }

    func testAcikCagriYaziciyiKurar() async {
        let log = SurfaceLog()
        let task = Attribution.enableConversionWriterTask(
            schemaURL: url, events: ["first_open": 1], environment: env(log, data: goodJSON))
        let outcome = await task.value
        XCTAssertEqual(outcome, .wrote)
        XCTAssertEqual(log.all, [.init(fine: 5, coarse: "medium", lock: true)])
    }

    // MARK: Karar 2 — şema yoksa hiçbir şey

    func testSemaYokkenHicbirDegerYazilmaz() async {
        let cases: [(String, Data?)] = [
            ("indirilemedi", nil),
            ("boş", Data()),
            ("bozuk JSON", Data("{nope".utf8)),
            ("version yok", Data("{\"rules\": []}".utf8)),
            ("aralık dışı fine", Data("""
            {"version":1,"rules":[{"event":"first_open","min":1,"fine":64,"coarse":"low","lockWindow":false}]}
            """.utf8)),
            ("geçersiz coarse", Data("""
            {"version":1,"rules":[{"event":"first_open","min":1,"fine":3,"coarse":"top","lockWindow":false}]}
            """.utf8)),
        ]
        for (name, data) in cases {
            let log = SurfaceLog()
            let outcome = await ConversionWriter.run(
                schemaURL: url, events: ["first_open": 1], environment: env(log, data: data))
            XCTAssertEqual(outcome, .noSchema, name)
            XCTAssertTrue(log.all.isEmpty, name)
        }
    }

    func testHttpsOlmayanSemaAdresiIndirilmezBile() async {
        let log = SurfaceLog()
        let outcome = await ConversionWriter.run(
            schemaURL: URL(string: "http://cdn.example.com/s.json")!,
            events: ["first_open": 1], environment: env(log, data: goodJSON))
        XCTAssertEqual(outcome, .noSchema)
        XCTAssertEqual(log.fetches.count, 0)
        XCTAssertTrue(log.all.isEmpty)
    }

    func testKuralEslesmezseYazilmaz() async {
        let log = SurfaceLog()
        let outcome = await ConversionWriter.run(
            schemaURL: url, events: ["baska": 1], environment: env(log, data: goodJSON))
        XCTAssertEqual(outcome, .noMatchingRule)
        XCTAssertTrue(log.all.isEmpty)
    }

    // MARK: Karar 4 — tvOS

    func testTvOSTaYaziciHicCalismaz() async {
        let log = SurfaceLog()
        // `supported` verilmez: platformun kendi kararı sınanır.
        let outcome = await ConversionWriter.run(
            schemaURL: url, events: ["first_open": 1], environment: env(log, data: goodJSON, supported: nil))
        #if os(iOS)
        XCTAssertTrue(ConversionWriter.platformSupported)
        XCTAssertEqual(outcome, .wrote)
        XCTAssertEqual(log.all.count, 1)
        #else
        // tvOS (ve macOS): SKAdNetwork/AAK yok; ne indirir ne yazar.
        XCTAssertFalse(ConversionWriter.platformSupported)
        XCTAssertEqual(outcome, .unsupportedPlatform)
        XCTAssertEqual(log.fetches.count, 0)
        XCTAssertTrue(log.all.isEmpty)
        #endif
    }

    func testDesteklenmeyenPlatformdaAcikCagriDaSessizdir() async {
        let log = SurfaceLog()
        let task = Attribution.enableConversionWriterTask(
            schemaURL: url, events: ["first_open": 1], environment: env(log, data: goodJSON, supported: false))
        let outcome = await task.value
        XCTAssertEqual(outcome, .unsupportedPlatform)
        XCTAssertEqual(log.fetches.count, 0)
        XCTAssertTrue(log.all.isEmpty)
    }

    // MARK: Karar 5 — rıza kapısı YOK (SPEC §5)

    /// SPEC §5'in "Rıza yok" satırı SKAN/AAK değer güncellemesine açıkça izin verir: değer bize
    /// değil Apple'ın toplayıcısına gider ve kimlik taşımaz. Kontrol noktası host'un açık
    /// `enableConversionWriter` çağrısıdır; yazıcı varsayılan kapalıdır ve kendiliğinden kurulmaz.
    func testRizadanBagimsizYazilir() async {
        for a in [false, true] { for b in [false, true] { for c in [false, true] {
            let consent = Consent(analytics: a, attribution: b, adSharing: c)
            let log = SurfaceLog()
            let outcome = await ConversionWriter.run(
                schemaURL: url, events: ["first_open": 1], environment: env(log, data: goodJSON))
            XCTAssertEqual(outcome, .wrote, "\(consent)")
            XCTAssertEqual(log.all.count, 1, "\(consent)")
        } } }
    }

    // MARK: Karar 6/7 — apply, saf kural tablosu

    func testKuralTablosuDogruFineVeCoarseUretir() {
        let s = schema([
            rule("first_open", fine: 2, coarse: "low"),
            rule("signup", fine: 10, coarse: "medium"),
            rule("purchase", min: 1, fine: 30, coarse: "high"),
            rule("purchase", min: 3, fine: 55, coarse: "high", lock: true),
        ])
        typealias Row = (events: [String: Int], fine: Int, coarse: String, lock: Bool)
        let table: [Row] = [
            (["first_open": 1], 2, "low", false),
            (["first_open": 1, "signup": 1], 10, "medium", false),
            (["signup": 5], 10, "medium", false),
            (["first_open": 1, "purchase": 1], 30, "high", false),
            (["purchase": 2], 30, "high", false),
            (["purchase": 3], 55, "high", true),
            (["first_open": 9, "signup": 9, "purchase": 9], 55, "high", true),
        ]
        for row in table {
            let r = ConversionWriter.apply(s, events: row.events)
            XCTAssertEqual(r?.fine, row.fine, "\(row.events)")
            XCTAssertEqual(r?.coarse, row.coarse, "\(row.events)")
            XCTAssertEqual(r?.lock, row.lock, "\(row.events)")
        }
        XCTAssertNil(ConversionWriter.apply(s, events: [:]))
        XCTAssertNil(ConversionWriter.apply(s, events: ["unknown": 99]))
        XCTAssertNil(ConversionWriter.apply(s, events: ["purchase": 0]))
    }

    func testLockWindowKuraldanGelir() {
        let locked = schema([rule("a", fine: 1, lock: true)])
        let open = schema([rule("a", fine: 1, lock: false)])
        XCTAssertEqual(ConversionWriter.apply(locked, events: ["a": 1])?.lock, true)
        XCTAssertEqual(ConversionWriter.apply(open, events: ["a": 1])?.lock, false)
    }

    func testEsitFineIlkKuralKazanir() {
        let s = schema([rule("a", fine: 7, coarse: "low"), rule("b", fine: 7, coarse: "high")])
        XCTAssertEqual(ConversionWriter.apply(s, events: ["a": 1, "b": 1])?.coarse, "low")
    }

    func testApplyGecersizSemayiUygulamaz() {
        // Doğrudan kurulmuş (decode'u atlayan) bozuk şema da yazdırmaz; kırpma yok.
        XCTAssertNil(ConversionWriter.apply(schema([rule("a", fine: 64)]), events: ["a": 1]))
        XCTAssertNil(ConversionWriter.apply(schema([rule("a", fine: -1)]), events: ["a": 1]))
        XCTAssertNil(ConversionWriter.apply(schema([rule("a", fine: 1, coarse: "top")]), events: ["a": 1]))
        XCTAssertNil(ConversionWriter.apply(schema([rule("a", fine: 1)], version: 0), events: ["a": 1]))
        // Bozuk kural geçerli olanı da götürür: yarım şema yok.
        XCTAssertNil(ConversionWriter.apply(schema([rule("a", fine: 1), rule("b", fine: 64)]), events: ["a": 1]))
    }
}

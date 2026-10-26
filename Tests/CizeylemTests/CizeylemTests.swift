import XCTest
@testable import Cizeylem

// MARK: - Test altyapısı

/// Sahte ağ. `@unchecked` kaçışı yok: durum aktörde.
private actor Net: BatchSending {
    typealias Responder = @Sendable (Int) -> (Outcome, Double?)
    private(set) var bodies: [String] = []
    private let responder: Responder

    init(_ responder: @escaping Responder = { _ in (.ok, nil) }) { self.responder = responder }

    func send(body: String) async -> (Outcome, retryAfter: Double?) {
        let i = bodies.count
        bodies.append(body)
        return responder(i)
    }

    var count: Int { bodies.count }

    /// Gönderilen tüm event'lerin JSON nesneleri (actor sınırını geçmesin diye burada çözülür).
    var events: [EvSnapshot] {
        bodies.flatMap { body -> [EvSnapshot] in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                  let list = o["events"] as? [[String: Any]] else { return [] }
            return list.map { EvSnapshot($0) }
        }
    }

    var sentAts: [Int64] {
        bodies.compactMap {
            guard let o = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] else { return nil }
            return (o["sent_at"] as? NSNumber)?.int64Value
        }
    }
}

/// Bir event'in test tarafındaki `Sendable` görünümü.
private struct EvSnapshot: Sendable {
    let name: String
    let distinctId: String
    let userId: String?
    let sessionId: String
    let time: Int64
    let props: [String: String]
    let set: [String: String]
    let setOnce: [String: String]
    let add: [String: String]
    let unset: [String]
    let context: [String: String]
    let keys: [String]

    init(_ o: [String: Any]) {
        name = o["event"] as? String ?? "?"
        distinctId = o["distinct_id"] as? String ?? "?"
        userId = o["user_id"] as? String
        sessionId = o["session_id"] as? String ?? "?"
        time = (o["time"] as? NSNumber)?.int64Value ?? -1
        props = EvSnapshot.flat(o["props"])
        set = EvSnapshot.flat(o["$set"])
        setOnce = EvSnapshot.flat(o["$set_once"])
        add = EvSnapshot.flat(o["$add"])
        unset = o["$unset"] as? [String] ?? []
        context = EvSnapshot.flat(o["context"])
        keys = (o.keys.map { $0 }).sorted()
    }

    private static func flat(_ any: Any?) -> [String: String] {
        guard let m = any as? [String: Any] else { return [:] }
        return m.mapValues { v in v is NSNull ? "<null>" : "\(v)" }
    }
}

/// Dosya destekli sahte duvar saati (ms). `DispatcherTests` ile aynı kalıp.
private final class WallClock: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cz-wall-\(UUID().uuidString)")

    init(ms: Int64 = 1_760_000_000_000) { set(ms) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func set(_ ms: Int64) { try? Data(String(ms).utf8).write(to: url) }
    func advance(_ ms: Int64) { set(current + ms) }
    var current: Int64 { WallClock.read(url) }
    var seconds: @Sendable () -> Double { { [url] in Double(WallClock.read(url)) / 1000 } }

    private static func read(_ url: URL) -> Int64 {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int64($0) } ?? 0
    }
}

/// Zamanlayıcı dikişi: istenen aralığı kaydeder ve gerçek 30 sn yerine kısa bir süre bekler.
/// Sabit (hemen dönen) bir dikiş, zamanlayıcının ilk turunu testin `track()`'inden ÖNCE
/// çalıştırıp testi yanıltıcı biçimde kırardı.
private actor Ticker {
    private(set) var intervals: [TimeInterval] = []
    private let delayNs: UInt64
    init(delayMs: UInt64 = 20) { delayNs = delayMs * 1_000_000 }
    func tick(_ i: TimeInterval) async {
        intervals.append(i)
        try? await Task.sleep(nanoseconds: delayNs)
    }
}

/// `Core`'un üretim yolunda ana thread'e düşmediğini kanıtlamak için `uuid` dikişinde thread kaydı.
private actor ThreadLog {
    private(set) var mainHits = 0
    private(set) var total = 0
    func record(_ onMain: Bool) {
        total += 1
        if onMain { mainHits += 1 }
    }
}

final class CizeylemTests: XCTestCase {
    /// Rızasız iz testinin baytını karşılaştırdığı KÖK: her şey bunun altında olmalı.
    private var root: URL!
    /// SDK deposu. Bilerek yaratılmaz: rızasızken var olmaması gerekiyor.
    private var dir: URL!
    private var suite: String!
    /// Yaşam döngüsü durumu: bilerek `root`'un DIŞINDA (üretimde de kuyruk dizininden bağımsız).
    private var lifeDir: URL!
    private var life: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cz-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dir = root.appendingPathComponent("store", isDirectory: true)
        lifeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cz-life-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lifeDir, withIntermediateDirectories: true)
        life = lifeDir.appendingPathComponent("state")
        suite = "co.cizeylem.test.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: lifeDir)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: - Yardımcılar

    private func platform(_ name: String = "ios", flushAt: Int = 30) -> Platform {
        Platform(name: name, queueDirectory: dir, maxEvents: 1000, maxBytes: 5 * 1024 * 1024, flushAt: flushAt)
    }

    private func config(flushAt: Int? = nil, legacyAmplitude: Bool = false) -> Configuration {
        Configuration(writeKey: "ck_w_test", flushAt: flushAt, flushInterval: 30, legacyAmplitude: legacyAmplitude)
    }

    private func deps(
        _ net: Net,
        platform p: Platform? = nil,
        clock: WallClock? = nil,
        uuids: [String] = [],
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        freshLifecycle: Bool = false
    ) -> Core.Dependencies {
        var d = Core.Dependencies()
        d.platform = p ?? platform()
        d.defaultsSuite = suite
        // Tohumlanmış durum = "ilk açılış değil": sürüm bilinmediği için ne `installed` ne
        // `updated` üretilir, böylece event dizisi yalnız testin kendi çağrılarından oluşur.
        if !freshLifecycle { try? Data("{}".utf8).write(to: life) }
        d.lifecycle = LifecycleLocation(url: life, usesDefaults: false)
        d.amplitudeLibraryDirectory = root.appendingPathComponent("amp")
        d.makeTransport = { _ in net }
        d.random = { 1 }
        if let clock { d.now = clock.seconds }
        if !uuids.isEmpty {
            let box = UUIDBox(uuids)
            d.uuid = { box.next() }
        }
        if let sleep { d.sleep = sleep }
        return d
    }

    private func core(_ net: Net, _ d: Core.Dependencies? = nil, _ c: Configuration? = nil) -> Core {
        Core(config: c ?? config(), deps: d ?? deps(net))
    }

    /// Dizin ağacının bayt bayt anlık görüntüsü (göreli yol → içerik).
    private func snapshot(_ url: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return out }
        for case let f as URL in walker {
            out[f.path.replacingOccurrences(of: url.path, with: "")] = (try? Data(contentsOf: f)) ?? Data()
        }
        return out
    }

    private func defaultsDomain() -> [String: Any] {
        UserDefaults().persistentDomain(forName: suite) ?? [:]
    }

    private func waitUntil(_ timeout: Double = 3, _ cond: () async -> Bool) async -> Bool {
        let steps = Int(timeout / 0.01)
        for _ in 0..<steps {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await cond()
    }

    private func grant(_ c: Core, _ consent: Consent = Consent(analytics: true)) async {
        await c.start()
        await c.setConsent(consent)
    }

    // MARK: - 1. Kurulum ve rıza kapısı

    func testInitializeCagrilmadanTrackCokmez() {
        // Facade üretim yolunda: hiçbir çağrı fırlatmamalı, çökmemeli, bloklamamalı.
        Cizeylem.track("cagri_yok")
        Cizeylem.identify("u1")
        Cizeylem.setUserProperties(["a": 1])
        Cizeylem.setUserPropertiesOnce(["b": 2])
        Cizeylem.addUserProperties(["c": 3])
        Cizeylem.unsetUserProperties(["d"])
        Cizeylem.sendUserProperties()
        Cizeylem.setConsent(Consent())
        Cizeylem.setOptOut(true)
        Cizeylem.handleDeepLink(URL(string: "https://example.com/?utm_source=x")!)
        Cizeylem.flush()
        Cizeylem.reset()
    }

    func testRizaYokkenInitTrackFlushHicbirIzBirakmaz() async throws {
        let before = snapshot(root)
        XCTAssertTrue(before.isEmpty, "test kökü boş başlamalı")

        let net = Net()
        let c = core(net, deps(net), config(legacyAmplitude: true))
        await c.start()
        await c.track("deneme", ["a": .int(1)])
        await c.identify("u1")
        await c.setUserProperties(["x": .string("y")])
        await c.sendUserProperties(userId: "u2")
        await c.handleDeepLink(URL(string: "https://example.com/?utm_source=meta")!)
        await c.reset()
        await c.flush()
        await c.shutdown()

        XCTAssertEqual(snapshot(root), before, "rızasızken diskte TEK BAYT değişmemeli")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "depo dizini bile yaratılmamalı")
        XCTAssertTrue(defaultsDomain().isEmpty, "UserDefaults'a da yazılmamalı")
        let sent = await net.count
        XCTAssertEqual(sent, 0, "ağa çıkılmamalı")
        let s = await c.stats()
        XCTAssertEqual(s.queued, 0)
        XCTAssertEqual(s.consent, Consent())
        let _h1 = await c.distinctId()
        XCTAssertNil(_h1)
    }

    func testRizaVerilinceEventGonderilir() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.track("satin_alma", ["tutar": .int(42)])
        await c.flush()

        let evs = await net.events
        XCTAssertEqual(evs.map(\.name), ["satin_alma"])
        XCTAssertEqual(evs[0].props, ["tutar": "42"])
        XCTAssertEqual(evs[0].context["lib"], "bir-ios")
        XCTAssertEqual(evs[0].context["consent_scope"], "analytics")
        XCTAssertFalse(evs[0].distinctId.isEmpty)
        await c.shutdown()
    }

    func testRizaYokkenGozlemciKurulmaz() async {
        let net = Net()
        let center = NotificationCenter()
        var d = deps(net)
        d.notificationCenter = center
        let c = Core(config: config(), deps: d)
        await c.start()
        center.post(name: LifecycleObserver.activeName, object: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await c.flush()
        let n = await net.count
        XCTAssertEqual(n, 0, "rızasız gözlemci HİÇ kurulmaz, bildirim event üretmez")
        let st = await c.stats()
        XCTAssertFalse(st.running, "kalıcı katman hiç kurulmaz")
        await c.shutdown()
    }

    func testRizaVerilinceGozlemciKurulurVeInstalledUretilir() async {
        let net = Net()
        let center = NotificationCenter()
        var d = deps(net, freshLifecycle: true)
        d.notificationCenter = center
        let c = Core(config: config(), deps: d)
        await grant(c)
        _ = await waitUntil { await c.stats().queued >= 1 }
        await c.flush()
        let names = await net.events.map(\.name)
        XCTAssertEqual(names.first, "cz_app_installed")
        await c.shutdown()
    }

    func testTekGozlemciOrnegiKurulur() async {
        // Madde 19: tekrar `setConsent(analytics:true)` ikinci bir gözlemci kurmamalı.
        let net = Net()
        let center = NotificationCenter()
        var d = deps(net, freshLifecycle: true)
        d.notificationCenter = center
        let c = Core(config: config(), deps: d)
        await grant(c)
        _ = await waitUntil { await c.stats().queued >= 1 }
        await c.setConsent(Consent(analytics: true, attribution: true))
        center.post(name: LifecycleObserver.activeName, object: nil)
        _ = await waitUntil { await c.stats().queued >= 2 }
        try? await Task.sleep(nanoseconds: 250_000_000)
        await c.flush()
        let names = await net.events.map(\.name)
        XCTAssertEqual(names, ["cz_app_installed", "cz_app_opened"], "tek gözlemci → tek çift event")
        await c.shutdown()
    }

    // MARK: - 2. Rıza geri alma (madde 8, 9)

    func testRizaGeriAlinincaKuyrukDeviceIdVeDurumSilinir() async {
        let net = Net { _ in (.retry, 9999) }   // gönderilmesin, kuyrukta kalsın
        let center = NotificationCenter()
        var d = deps(net)
        d.notificationCenter = center
        let c = Core(config: config(), deps: d)
        await grant(c)
        await c.track("e1")
        _ = await waitUntil { await c.stats().queued >= 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("device_id").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: life.path))

        await c.setConsent(Consent())

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue.jsonl").path), "kuyruk silinir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("device_id").path), "device_id silinir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("consent").path), "rıza dosyası silinir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: life.path), "yaşam döngüsü durumu silinir")
        let s = await c.stats()
        XCTAssertEqual(s.queued, 0)
        let _h2 = await c.distinctId()
        XCTAssertNil(_h2)

        // Gözlemci bırakıldı: bildirim artık event üretmez.
        center.post(name: LifecycleObserver.activeName, object: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let _h3 = await c.stats().queued
        XCTAssertEqual(_h3, 0)
        await c.shutdown()
    }

    func testOkumaHatasiKuyrugiVeDeviceIdSilmez() async throws {
        // Madde 9 / TUZAK: `ConsentStore.read()` "okunamadı" ile "geri alındı" ayrımını yapmaz.
        // Geçici okuma hatası (kilitli cihazda arka plan başlatma) veriyi YOK ETMEMELİ.
        let net = Net { _ in (.retry, 9999) }
        let c1 = core(net)
        await grant(c1)
        await c1.track("e1")
        _ = await waitUntil { await c1.stats().queued >= 1 }
        await c1.shutdown()
        let queueBytes = try Data(contentsOf: dir.appendingPathComponent("queue.jsonl"))
        let idBytes = try Data(contentsOf: dir.appendingPathComponent("device_id"))

        // İkinci süreç: rıza dosyası OKUNAMIYOR (dosya duruyor).
        var d = deps(net)
        d.consentReadFile = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
        let c2 = Core(config: config(), deps: d)
        await c2.start()
        await c2.track("e2")
        await c2.flush()
        await c2.shutdown()

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("queue.jsonl")), queueBytes,
                       "okuma hatası kuyruğu SİLMEZ")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("device_id")), idBytes,
                       "okuma hatası device_id'yi SİLMEZ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("consent").path),
                      "rıza dosyasına da dokunulmaz")
        let sent = await net.count
        XCTAssertEqual(sent, 0, "ama fail-closed: okunamayan rıza ile event de yazılmaz/gönderilmez")
    }

    func testGeriAlmaSonrasiYenidenRizaEskiKimligiDIRILTMEZ() async {
        // Important 1: `erase()` BİZİM depomuzu siler ama Amplitude'unkini silemez. Devralma
        // zinciri baştan koşarsa açık "beni unut" talebi boşa çıkar, kullanıcı sunucudaki eski
        // profiline yeniden bağlanır, `migrated_from` ve `cz_app_installed` ikinci kez gider.
        let net = Net()
        let center = NotificationCenter()
        var d = deps(net, freshLifecycle: true)
        d.notificationCenter = center
        d.takeoverOverride = Takeover(deviceId: "amplitude-id", source: "amplitude-swift", optOut: false)
        let c = Core(config: Configuration(writeKey: "ck_w_test", legacyAmplitude: true), deps: d)

        await grant(c)
        let ilk = await c.distinctId()
        XCTAssertEqual(ilk, "amplitude-id", "ilk rızada devralma çalışır")
        _ = await waitUntil { await c.stats().queued >= 1 }
        await c.flush()

        await c.setConsent(Consent())              // açık "beni unut"
        await c.setConsent(Consent(analytics: true))  // ayar ekranında geri açıldı
        await c.track("yeniden")
        _ = await waitUntil { await c.stats().queued >= 1 }
        await c.flush()

        let yeni = await c.distinctId()
        XCTAssertNotNil(yeni)
        XCTAssertNotEqual(yeni, "amplitude-id", "(a) geri almadan sonra eski kimlik DİRİLMEZ")
        XCTAssertNotNil(UUID(uuidString: yeni ?? ""), "taze anonim kimlik UUID'dir")

        let evs = await net.events
        let sonrakiler = evs.drop { $0.name != "yeniden" && $0.distinctId == "amplitude-id" }
        XCTAssertEqual(evs.filter { !$0.setOnce.isEmpty && $0.distinctId == yeni }.count, 0,
                       "(b) `migrated_from` ikinci kez gitmez")
        XCTAssertEqual(evs.filter { $0.name == "cz_app_installed" && $0.distinctId == yeni }.count, 0,
                       "(c) aynı/yeni kimliğe ikinci `cz_app_installed` yazılmaz")
        XCTAssertEqual(sonrakiler.filter { $0.name == "yeniden" }.count, 1)
        await c.shutdown()
    }

    func testGeriAlmaSonrasiTazeKimlikKALICIDIR() async throws {
        // Düzeltmenin kalıcı olması buna bağlı: taze kimlik rıza geri verilir verilmez
        // **hemen** diske yazılmalı. Beklenirse (ilk event'e kadar) süreç aradaki boşlukta
        // ölünce sonraki süreç boş depo + bayraksız başlar ve devralma yeniden koşar.
        // Bu yüzden burada `distinctId()`/`track()` ÇAĞIRILMAZ: yazımı tetikleyen tek şey
        // rıza geri verilmesi olmalı.
        let net = Net()
        var d = deps(net)
        d.takeoverOverride = Takeover(deviceId: "amplitude-id", source: "amplitude-swift", optOut: false)
        let cfg = Configuration(writeKey: "ck_w_test", legacyAmplitude: true)

        let c1 = Core(config: cfg, deps: d)
        await grant(c1)
        await c1.setConsent(Consent())
        await c1.setConsent(Consent(analytics: true))
        await c1.shutdown()

        let idFile = dir.appendingPathComponent("device_id")
        let taze = try String(contentsOf: idFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(taze, "amplitude-id", "taze kimlik rıza geri verilince HEMEN yazılır")
        XCTAssertNotNil(UUID(uuidString: taze))

        let c2 = Core(config: cfg, deps: d)
        await c2.start()
        let c2Id = await c2.distinctId()
        XCTAssertEqual(c2Id, taze, "sonraki süreç kendi depomuzu görür, devralma koşmaz")
        await c2.track("ikinci_surec")
        await c2.flush()
        let evs = await net.events.filter { $0.name == "ikinci_surec" }
        XCTAssertEqual(evs[0].setOnce, [:], "sonraki süreçte de `migrated_from` yok")
        XCTAssertEqual(evs[0].distinctId, taze)
        await c2.shutdown()
    }

    func testGeriAlmaSonrasiTazeKimlikYazilamazsaBenimsenmezVeUyarilir() async throws {
        // Yazım doğrulanmadan kimlik benimsenirse: bellekte taze kimlik, diskte hiçbir şey.
        // Süreç ölünce sonraki süreç boş depo + bayraksız başlar ve devralma DİRİLİR.
        let net = Net()
        let logged = LogBox()
        var d = deps(net)
        d.takeoverOverride = Takeover(deviceId: "amplitude-id", source: "amplitude-swift", optOut: false)
        let cfg = Configuration(writeKey: "ck_w_test", legacyAmplitude: true,
                                logger: { [logged] m in logged.add(m) })
        let c = Core(config: cfg, deps: d)
        await grant(c)
        await c.setConsent(Consent())   // `erase()` dizini komple siler

        // Yazımı düşüren dikiş geri almadan SONRA kurulur.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("device_id"), withIntermediateDirectories: true)
        await c.setConsent(Consent(analytics: true))

        XCTAssertTrue(logged.contains("geri alma sonrası taze kimlik yazılamadı"),
                      "yazılamayan taze kimlik sessizce benimsenmez")
        let id = await c.distinctId()
        XCTAssertNil(id, "diske yazılamayan kimlik kullanılmaz")
        XCTAssertFalse(logged.contains("migrated_from"))
        await c.shutdown()
    }

    func testKimlikYokkenIdentifyUserIdBaginiKOPARMAZ() async {
        // Important 2: `$identify` üretilemediyse `user_id` kalıcı YAZILMAMALI; yoksa eski
        // anonim `distinct_id` ile `user_id` arasındaki bağ kalıcı olarak kaybolur.
        let net = Net()
        let locked = LockBox()
        var d = deps(net)
        d.deviceIdReadFile = { url in
            if locked.isLocked { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            return try Data(contentsOf: url)
        }
        let c = Core(config: config(), deps: d)
        await grant(c)

        await c.identify("u-bagli")
        let kilitliId = await c.distinctId()
        XCTAssertNil(kilitliId, "kilitliyken user_id benimsenmez")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("user_id").path),
                       "user_id kalıcı YAZILMAZ")

        locked.unlock()
        let anon = await c.distinctId()
        XCTAssertNotNil(anon)
        await c.identify("u-bagli")
        await c.flush()
        let evs = await net.events.filter { $0.name == "$identify" }
        XCTAssertEqual(evs.count, 1, "bağ kilit açılınca kurulur")
        XCTAssertEqual(evs[0].distinctId, anon, "$identify ESKİ anonim distinct_id ile gider")
        XCTAssertEqual(evs[0].userId, "u-bagli")
        let sonId = await c.distinctId()
        XCTAssertEqual(sonId, "u-bagli")
        await c.shutdown()
    }

    func testKimlikYokkenSendUserPropertiesUserIdYazmaz() async {
        let net = Net()
        let locked = LockBox()
        var d = deps(net)
        d.deviceIdReadFile = { url in
            if locked.isLocked { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            return try Data(contentsOf: url)
        }
        let c = Core(config: config(), deps: d)
        await grant(c)
        await c.setUserProperties(["a": .string("b")])
        await c.sendUserProperties(userId: "u-2")

        let kilitliId = await c.distinctId()
        XCTAssertNil(kilitliId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("user_id").path))

        locked.unlock()
        let anon = await c.distinctId()
        await c.sendUserProperties(userId: "u-2")
        await c.flush()
        let evs = await net.events.filter { $0.name == "$identify" }
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].distinctId, anon)
        XCTAssertEqual(evs[0].userId, "u-2")
        XCTAssertEqual(evs[0].set, ["a": "b"], "bekleyenler de korunmuştu")
        await c.shutdown()
    }

    // MARK: - 3. Rıza yazımı başarısız (madde 1)

    /// Yazım yolunu düşüren dikiş: rıza dosyasının yerine (boş) bir DİZİN konur.
    /// `Data.write` düşer, `removeItem` o dizini kaldırabilir — gerçek üretim hatalarının
    /// (disk dolu, veri koruması) davranışı budur: yazamayız ama silebiliriz.
    private func breakConsentWrite() throws {
        let file = dir.appendingPathComponent("consent")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    }

    func testRizaYazimiDusersaKayitSilinirVeBellekteGecerliKalir() async throws {
        let net = Net()
        let c = core(net)
        await grant(c)
        let consentFile = dir.appendingPathComponent("consent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: consentFile.path))

        try breakConsentWrite()
        await c.setConsent(Consent(analytics: true, attribution: true))

        XCTAssertFalse(FileManager.default.fileExists(atPath: consentFile.path),
                       "yazım düşerse kayıt SİLİNİR (sonraki süreç rızasız başlar, host yeniden sorar)")
        let s = await c.stats()
        XCTAssertEqual(s.consent, Consent(analytics: true, attribution: true),
                       "bu süreçte bellekteki rıza geçerli kalır")
        await c.shutdown()
    }

    func testKismiDaraltmaYazimiDusersaKayitSilinir() async throws {
        let net = Net()
        let c = core(net)
        await c.start()
        await c.setConsent(Consent(analytics: true, attribution: true, adSharing: true))
        let consentFile = dir.appendingPathComponent("consent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: consentFile.path))

        try breakConsentWrite()
        // Üçten ikiye iniş: DARALTMA. Yazılamadıysa eski GENİŞ kayıt diskte kalmamalı.
        await c.setConsent(Consent(analytics: true, attribution: true))

        XCTAssertFalse(FileManager.default.fileExists(atPath: consentFile.path),
                       "kısmi daraltma da yazılamazsa kayıt silinir")
        let s = await c.stats()
        XCTAssertEqual(s.consent, Consent(analytics: true, attribution: true))
        await c.shutdown()
    }

    func testRizaGeriAlmaYazimiDusersaBellekteKapaliKalir() async throws {
        let net = Net()
        let c = core(net)
        await grant(c)
        try breakConsentWrite()
        await c.setConsent(Consent())

        let s = await c.stats()
        XCTAssertEqual(s.consent, Consent(), "geri alma yönünde de bellekte GEÇERLİ")
        XCTAssertFalse(s.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "kalıcı iz kalmaz")
        await c.track("sonrasinda")
        let sent = await net.count
        XCTAssertEqual(sent, 0)
    }

    func testHemYazimHemSilmeDusersaBellekKapanirVeUyarilir() async throws {
        // Bilinen artık risk: salt-okunur dizinde `write` DE `remove` DE düşer; eski kayıt
        // diskte kalır ve sonraki SÜREÇ onu okur. Bu süreçte doğru davrandığımızı kilitliyoruz.
        try XCTSkipIf(getuid() == 0, "root izin kontrollerini atlar")
        let net = Net()
        let logged = LogBox()
        let cfg = Configuration(writeKey: "ck_w_test", flushInterval: 30, legacyAmplitude: false,
                                logger: { [logged] m in logged.add(m) })
        let c = Core(config: cfg, deps: deps(net))
        await grant(c)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        await c.setConsent(Consent())

        let s = await c.stats()
        XCTAssertEqual(s.consent, Consent(), "bellekte kapalı: bu süreçte artık yazmayız")
        XCTAssertTrue(logged.contains("rıza diske yazılamadı"), "sessiz kalmaz")
        await c.track("yazilmaz")
        let sent = await net.count
        XCTAssertEqual(sent, 0)
    }

    // MARK: - 4. device_id üretilemiyor (madde 2)

    func testDeviceIdUretilemezseStatsGosterirVeSonraYenidenDenenir() async {
        let net = Net()
        let locked = LockBox()
        var d = deps(net)
        d.deviceIdReadFile = { url in
            if locked.isLocked { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            return try Data(contentsOf: url)
        }
        let c = Core(config: config(), deps: d)
        await grant(c)
        await c.track("e1")

        var s = await c.stats()
        XCTAssertFalse(s.deviceIdAvailable, "SDK sessizce ölmez: durum stats()'ta görünür")
        XCTAssertEqual(s.queued, 0, "kimliksiz event yazılmaz")
        let _h4 = await c.distinctId()
        XCTAssertNil(_h4)

        locked.unlock()
        await c.track("e2")
        s = await c.stats()
        XCTAssertTrue(s.deviceIdAvailable, "sonraki çağrıda YENİDEN denenir")
        XCTAssertEqual(s.queued, 1)
        await c.flush()
        let names = await net.events.map(\.name)
        XCTAssertEqual(names, ["e2"])
        await c.shutdown()
    }

    func testBekleyenPropertylerYazmaHatasindaKaybolmaz() async {
        // Madde 3: Android'de `takePending` yazma düşünce bekleyenleri siliyordu.
        let net = Net()
        let locked = LockBox()
        var d = deps(net)
        d.deviceIdReadFile = { url in
            if locked.isLocked { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            return try Data(contentsOf: url)
        }
        let c = Core(config: config(), deps: d)
        await grant(c)
        await c.setUserProperties(["plan": .string("pro")])
        await c.addUserProperties(["sayac": 2])
        await c.setUserPropertiesOnce(["ilk": .string("evet")])
        await c.unsetUserProperties(["eski"])

        await c.track("kayip_olmaz")      // device_id yok → yazılamaz
        let _h5 = await c.stats().queued
        XCTAssertEqual(_h5, 0)

        locked.unlock()
        await c.track("kayip_olmaz")
        await c.flush()
        let evs = await net.events
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].set, ["plan": "pro"], "$set korunur")
        XCTAssertEqual(evs[0].setOnce, ["ilk": "evet"], "$set_once korunur")
        XCTAssertEqual(evs[0].add, ["sayac": "2"], "$add korunur")
        XCTAssertEqual(evs[0].unset, ["eski"], "$unset korunur")
        await c.shutdown()
    }

    func testRizaGeriAlinincaBekleyenPropertylerDeSilinir() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.setUserProperties(["gizli": .string("v")])
        await c.setConsent(Consent())          // açık geri alma: kullanıcı verisi gider
        await c.setConsent(Consent(analytics: true))
        await c.track("yeniden")
        await c.flush()
        let evs = await net.events.filter { $0.name == "yeniden" }
        XCTAssertEqual(evs[0].set, [:], "geri alınmış oturumun bekleyen property'leri taşınmaz")
        await c.shutdown()
    }

    func testDevralinanKimlikYazilamazsaIsaretlenmezVeUyarilir() async throws {
        // `device_id` yoluna bir DİZİN konur: yazım da okuma da düşer.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("device_id"), withIntermediateDirectories: true)
        let net = Net()
        let logged = LogBox()
        var d = deps(net)
        d.takeoverOverride = Takeover(deviceId: "eski-id", source: "amplitude-swift", optOut: true)
        let cfg = Configuration(writeKey: "ck_w_test", legacyAmplitude: true,
                                logger: { [logged] m in logged.add(m) })
        let c = Core(config: cfg, deps: d)
        await grant(c)
        await c.track("e")

        XCTAssertTrue(logged.contains("devralınan device_id yazılamadı"),
                      "yazılamayan devralma sessizce 'olmuş' sayılmaz")
        let s = await c.stats()
        XCTAssertFalse(s.deviceIdAvailable)
        XCTAssertEqual(s.queued, 0)
        await c.shutdown()
    }

    // MARK: - 5. Kimlik (madde 7)

    func testIdentifySonrasiDistinctIdUserIdOlur() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        let anon = await c.distinctId()
        XCTAssertNotNil(anon)

        await c.identify("kullanici-7", ["plan": .string("pro")])
        let _h6 = await c.distinctId()
        XCTAssertEqual(_h6, "kullanici-7")

        await c.track("sonraki")
        await c.flush()
        let evs = await net.events.filter { $0.name != "cz_app_installed" }
        XCTAssertEqual(evs.map(\.name), ["$identify", "sonraki"])
        XCTAssertEqual(evs[0].distinctId, anon, "$identify ESKİ anonim kimliği taşır")
        XCTAssertEqual(evs[0].userId, "kullanici-7")
        XCTAssertEqual(evs[0].set, ["plan": "pro"])
        XCTAssertEqual(evs[1].distinctId, "kullanici-7", "sonrası user_id ile gider")
        XCTAssertNil(evs[1].userId, "normal event'te user_id alanı yok (bir-js parity)")
        await c.shutdown()
    }

    func testIdentifyUserIdKaliciYazilir() async {
        let net = Net()
        let d = deps(net)
        let c1 = Core(config: config(), deps: d)
        await grant(c1)
        await c1.identify("kalici-u")
        await c1.shutdown()

        let c2 = Core(config: config(), deps: d)
        await c2.start()
        let _h7 = await c2.distinctId()
        XCTAssertEqual(_h7, "kalici-u", "user_id süreçler arası kalıcıdır")
        await c2.shutdown()
    }

    func testResetYeniAnonimKimlikUretir() async {
        let net = Net()
        let d = deps(net)
        let c1 = Core(config: config(), deps: d)
        await grant(c1)
        let ilk = await c1.distinctId()
        await c1.identify("u-9")
        let _h8 = await c1.distinctId()
        XCTAssertEqual(_h8, "u-9")

        await c1.reset()
        let yeni = await c1.distinctId()
        XCTAssertNotNil(yeni)
        XCTAssertNotEqual(yeni, "u-9", "reset user_id'yi bırakır")
        XCTAssertNotEqual(yeni, ilk, "reset YENİ anonim UUID üretir")
        XCTAssertNotNil(UUID(uuidString: yeni ?? ""), "anonim kimlik UUID'dir")
        await c1.shutdown()

        let c2 = Core(config: config(), deps: d)
        await c2.start()
        let _h9 = await c2.distinctId()
        XCTAssertEqual(_h9, yeni, "yeni kimlik ve user_id silinişi kalıcıdır")
        await c2.shutdown()
    }

    func testResetBekleyenPropertyleriDeTemizler() async {
        // Kullanıcı sınırı: eski kullanıcının bekleyen operasyonları YENİ anonim kimliğe
        // yazılamaz. `bir-js` bunu temizlemiyor; bilinçli sapma (kullanıcılar arası sızıntı).
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.setUserProperties(["plan": .string("pro")])
        await c.setUserPropertiesOnce(["ilk": .string("evet")])
        await c.addUserProperties(["sayac": 3])
        await c.unsetUserProperties(["eski"])

        await c.reset()
        await c.track("reset_sonrasi")
        await c.flush()

        let evs = await net.events.filter { $0.name == "reset_sonrasi" }
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].set, [:], "eski kullanıcının $set'i yeni kimliğe sızmaz")
        XCTAssertEqual(evs[0].setOnce, [:], "$set_once sızmaz")
        XCTAssertEqual(evs[0].add, [:], "$add sızmaz")
        XCTAssertEqual(evs[0].unset, [], "$unset sızmaz")
        XCTAssertFalse(evs[0].keys.contains("$set"))
        await c.shutdown()
    }

    func testResetOturumuDaSifirlar() async {
        let net = Net()
        let clock = WallClock(ms: 1_777_000_000_000)
        let c = core(net, deps(net, clock: clock))
        await grant(c)
        await c.track("a")
        await c.reset()
        clock.advance(1)
        await c.track("b")
        await c.flush()
        let evs = await net.events
        let a = evs.first { $0.name == "a" }?.sessionId
        let b = evs.first { $0.name == "b" }?.sessionId
        XCTAssertEqual(a, "1777000000000")
        XCTAssertEqual(b, "1777000000001", "yeni kullanıcı eskinin oturumunu sürdürmez")
        await c.shutdown()
    }

    func testDevralmaInstalledEventineExistingInstallYazar() async {
        let net = Net()
        var d = deps(net, freshLifecycle: true)
        d.takeoverOverride = Takeover(deviceId: "eski-id", source: "amplitude-swift", optOut: false)
        let c = Core(config: Configuration(writeKey: "ck_w_test", legacyAmplitude: true), deps: d)
        await grant(c)
        _ = await waitUntil { await c.stats().queued >= 1 }
        await c.flush()
        let evs = await net.events.filter { $0.name == "cz_app_installed" }
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].props["existing_install"], "1", "devralma olduysa existing_install true")
        await c.shutdown()
    }

    func testOnPlanaGecinceAppStateForegroundOlur() async {
        let net = Net()
        let center = NotificationCenter()
        var d = deps(net, platform: platform(flushAt: 100))
        d.notificationCenter = center
        let c = Core(config: config(), deps: d)
        await grant(c)
        center.post(name: LifecycleObserver.activeName, object: nil)
        _ = await waitUntil { await c.stats().queued >= 1 }
        await c.track("sonra")
        await c.flush()
        let evs = await net.events
        XCTAssertEqual(evs.first { $0.name == "cz_app_opened" }?.context["app_state"], "foreground",
                       "`opened` kendi yeni durumunu taşır")
        XCTAssertEqual(evs.first { $0.name == "sonra" }?.context["app_state"], "foreground")
        await c.shutdown()
    }

    func testResetSunucuyaCagriYapmaz() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        let before = await net.count
        await c.reset()
        let _h10 = await net.count
        XCTAssertEqual(_h10, before)
        await c.shutdown()
    }

    func testSendUserPropertiesIdentifyUretir() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.setUserProperties(["a": .string("b")])
        await c.sendUserProperties(userId: nil)
        await c.flush()
        let evs = await net.events.filter { $0.name == "$identify" }
        XCTAssertEqual(evs.count, 1)
        XCTAssertNil(evs[0].userId, "anonim kullanıcıda da çalışır")
        XCTAssertEqual(evs[0].set, ["a": "b"])
        await c.shutdown()
    }

    func testSendUserPropertiesBosVeUserIdsizIseEventUretmez() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        let before = await c.stats().queued
        await c.sendUserProperties(userId: nil)
        let _h11 = await c.stats().queued
        XCTAssertEqual(_h11, before)
        await c.shutdown()
    }

    func testIdentifyPropsBekleyenSetiEzmez() async {
        // bir-js'te `$set` props ile EZİLİYOR (pendingSet önce boşaltıldığı için). Madde 3
        // "bekleyen property sessizce kaybolmasın" diyor: birleştiriyoruz, çakışmada props kazanır.
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.setUserProperties(["bekleyen": .string("v"), "ortak": .string("eski")])
        await c.identify("u", ["ortak": .string("yeni")])
        await c.flush()
        let evs = await net.events.filter { $0.name == "$identify" }
        XCTAssertEqual(evs[0].set, ["bekleyen": "v", "ortak": "yeni"])
        await c.shutdown()
    }

    func testBekleyenPropertylerIlkEventeIliştirilirVeBirKezGider() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.setUserProperties(["a": .string("1")])
        await c.addUserProperties(["n": 2])
        await c.addUserProperties(["n": 3])
        await c.track("ilk")
        await c.track("ikinci")
        await c.flush()
        let evs = await net.events.filter { $0.name.hasPrefix("i") }
        XCTAssertEqual(evs[0].set, ["a": "1"])
        XCTAssertEqual(evs[0].add, ["n": "5"], "addUserProperties birikir (bir-js parity)")
        XCTAssertEqual(evs[1].set, [:], "ikinci event'e iliştirilmez")
        XCTAssertEqual(evs[1].add, [:])
        await c.shutdown()
    }

    // MARK: - 6. Deep link

    func testHandleDeepLinkCzDeepLinkOpenedUretir() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.handleDeepLink(URL(string: "example://ac?utm_source=meta&click_id=k1&token=gizli")!)
        await c.flush()
        let evs = await net.events.filter { $0.name == "cz_deep_link_opened" }
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].props, ["utm_source": "meta", "click_id": "k1"])
        await c.shutdown()
    }

    func testHandleDeepLinkTamURLGondermez() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.handleDeepLink(URL(string: "example://ac?token=gizli")!)
        await c.flush()
        let evs = await net.events.filter { $0.name == "cz_deep_link_opened" }
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].props, [:], "beyaz liste dışı hiçbir şey, tam URL de gitmez")
        XCTAssertFalse(evs[0].keys.contains("url"))
        await c.shutdown()
    }

    // MARK: - 7. setOptOut (madde 5, 6)

    func testSetOptOutTrueUcRizaAnahtariniKapatir() async {
        let net = Net()
        let c = core(net)
        await c.start()
        await c.setConsent(Consent(analytics: true, attribution: true, adSharing: true))
        await c.setOptOut(true)
        let _h12 = await c.stats().consent
        XCTAssertEqual(_h12, Consent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("consent").path))
        await c.shutdown()
    }

    func testSetOptOutFalseYalnizAnalyticsiAcar() async {
        let net = Net()
        let c = core(net)
        await c.start()
        await c.setOptOut(false)
        let _h13 = await c.stats().consent
        XCTAssertEqual(_h13, Consent(analytics: true), "attribution/adSharing VARSAYILMAZ (en dar yorum)")
        await c.shutdown()
    }

    func testSetOptOutFalseVarOlanGenisRizayiDaraltir() async {
        let net = Net()
        let c = core(net)
        await c.start()
        await c.setConsent(Consent(analytics: true, attribution: true, adSharing: true))
        await c.setOptOut(false)
        let _h14 = await c.stats().consent
        XCTAssertEqual(_h14, Consent(analytics: true), "geriye uyumluluk API'si en dar yorumla uygulanır")
        await c.shutdown()
    }

    // MARK: - 8. Flush tetikleri

    func testFlushAtEsiginaUlasincaGonderimTetiklenir() async {
        let net = Net()
        let c = core(net, deps(net, platform: platform(flushAt: 3)))
        await grant(c)
        await c.track("a")
        await c.track("b")
        let _h15 = await net.count
        XCTAssertEqual(_h15, 0, "eşik altında ağa çıkılmaz")
        await c.track("c")
        let _h16 = await waitUntil { await net.count == 1 }
        XCTAssertTrue(_h16, "eşikte gönderim tetiklenir")
        await c.shutdown()
    }

    func testPlatformFlushAtiKullanilir() async {
        let net = Net()
        let c = core(net, deps(net, platform: platform("tvos", flushAt: 2)), config(flushAt: nil))
        let _h17 = await c.flushAt()
        XCTAssertEqual(_h17, 2, "flushAt verilmezse Platform.current.flushAt")
        await c.shutdown()
    }

    func test30SnGecinceZamanlayiciFlushTetikler() async {
        let net = Net()
        let ticker = Ticker()
        let c = core(net, deps(net, sleep: { [ticker] i in await ticker.tick(i) }))
        await grant(c)
        await c.track("zamanlayici")
        let _h18 = await waitUntil { await net.count >= 1 }
        XCTAssertTrue(_h18, "zamanlayıcı flush tetikler")
        let intervals = await ticker.intervals
        XCTAssertEqual(intervals.first, 30, "aralık Configuration.flushInterval")
        await c.shutdown()
    }

    func testShutdownZamanlayiciyiDurdurur() async {
        let net = Net()
        let ticker = Ticker()
        let c = core(net, deps(net, sleep: { [ticker] i in await ticker.tick(i) }))
        await grant(c)
        await c.shutdown()
        let after = await ticker.intervals.count
        try? await Task.sleep(nanoseconds: 150_000_000)
        let _h19 = await ticker.intervals.count
        XCTAssertLessThanOrEqual(_h19, after + 1, "iptal sonrası döngü durur")
    }

    // MARK: - 9. Ana thread (madde 12) ve saat (madde 11)

    func testTrackCagiranThreaddeDiskYazmaz() async {
        let log = ThreadLog()
        let net = Net()
        var d = deps(net)
        // `uuid` event kurulurken (insert_id) çağrılır: event üretimi ve kuyruk yazımı ORADA olur.
        d.uuid = { @Sendable in
            let onMain = Thread.isMainThread
            Task { await log.record(onMain) }
            return UUID().uuidString
        }
        let c = Core(config: config(), deps: d)
        await grant(c)
        await MainActor.run { XCTAssertTrue(Thread.isMainThread) }
        await c.track("ana_threadden")
        _ = await waitUntil { await log.total >= 1 }
        let _h20 = await log.total
        XCTAssertGreaterThan(_h20, 0)
        let _h21 = await log.mainHits
        XCTAssertEqual(_h21, 0, "event üretimi ve disk yazımı çağıranın (ana) thread'inde olmaz")
        await c.shutdown()
    }

    func testSentAtDuvarSaatindenGelir() async {
        // Madde 11: `sent_at` DUVAR saati. Monotonik saat (systemUptime) epoch değildir;
        // buraya sızarsa değer 2001 öncesine düşer ve bu test kırılır.
        let net = Net()
        let clock = WallClock(ms: 1_777_000_000_000)
        let c = core(net, deps(net, clock: clock))
        await grant(c)
        await c.track("a")
        await c.flush()
        clock.advance(5_000)
        await c.track("b")
        await c.flush()

        let sentAts = await net.sentAts
        XCTAssertEqual(sentAts, [1_777_000_000_000, 1_777_000_005_000])
        let times = await net.events.filter { $0.name == "a" || $0.name == "b" }.map(\.time)
        XCTAssertEqual(times, [1_777_000_000_000, 1_777_000_005_000], "`time` de duvar saati, ms")
        await c.shutdown()
    }

    func testSessionIdOturumBaslangicininEpochMsi() async {
        let net = Net()
        let clock = WallClock(ms: 1_777_000_000_000)
        let c = core(net, deps(net, clock: clock))
        await grant(c)
        await c.track("a")
        clock.advance(1_000)
        await c.track("b")
        await c.flush()
        let evs = await net.events.filter { $0.name == "a" || $0.name == "b" }
        XCTAssertEqual(evs[0].sessionId, "1777000000000")
        XCTAssertEqual(evs[1].sessionId, "1777000000000", "pencere içinde oturum sürer")
        await c.shutdown()
    }

    // MARK: - 10. `$` önekli anahtarlar (madde 15)

    func testDollarOnekliPropAnahtariSuzulur() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.track("e", ["$kotu": .int(1), "iyi": .int(2)])
        await c.flush()
        let evs = await net.events.filter { $0.name == "e" }
        XCTAssertEqual(evs[0].props, ["iyi": "2"], "sunucu `$` önekli prop görürse EVENT'İ düşürür")
        await c.shutdown()
    }

    func testDollarOnekliUserPropertyAnahtariSuzulur() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.setUserProperties(["$set": .int(1), "ok": .int(2)])
        await c.setUserPropertiesOnce(["$x": .int(1), "ok1": .int(2)])
        await c.addUserProperties(["$y": 1, "ok2": 2])
        await c.unsetUserProperties(["$z", "ok3"])
        await c.track("e")
        await c.flush()
        let evs = await net.events.filter { $0.name == "e" }
        XCTAssertEqual(evs[0].set, ["ok": "2"])
        XCTAssertEqual(evs[0].setOnce, ["ok1": "2"])
        XCTAssertEqual(evs[0].add, ["ok2": "2"])
        XCTAssertEqual(evs[0].unset, ["ok3"])
        await c.shutdown()
    }

    func testTumPropAnahtarlariDollarsaPropsAlaniYazilmaz() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.track("e", ["$a": .int(1)])
        await c.flush()
        let evs = await net.events.filter { $0.name == "e" }
        XCTAssertFalse(evs[0].keys.contains("props"), "boş `props` nesnesi hiç yazılmaz")
        await c.shutdown()
    }

    // MARK: - 11. Amplitude devralma (madde 4)

    func testDevralmaMigratedFromSetOnceIletir() async {
        let net = Net()
        let amp = root.appendingPathComponent("amp")
        try? FileManager.default.createDirectory(at: amp, withIntermediateDirectories: true)
        let c = core(net, deps(net), config(legacyAmplitude: true))
        await c.start()
        // Devralma kaynağı: açık `Configuration(deviceId:)` zincirin ilk halkası.
        let cfg = Configuration(writeKey: "ck_w_test", deviceId: "amp-id-1", legacyAmplitude: true)
        let c2 = Core(config: cfg, deps: deps(net))
        await grant(c2)
        await c2.track("e")
        await c2.flush()
        let _h22 = await c2.distinctId()
        XCTAssertEqual(_h22, "amp-id-1")
        let evs = await net.events.filter { $0.name == "e" }
        XCTAssertEqual(evs[0].setOnce["migrated_from"], "configured")
        await c.shutdown()
        await c2.shutdown()
    }

    func testAmplitudeOptOutTazeRizayiEzmezAmaSetOnceIleKorunur() async {
        let net = Net()
        let amp = root.appendingPathComponent("amp")
        try? FileManager.default.createDirectory(at: amp, withIntermediateDirectories: true)
        var d = deps(net)
        d.takeoverOverride = Takeover(deviceId: "eski-id", source: "amplitude-sqlite", optOut: true)
        let c = Core(config: Configuration(writeKey: "ck_w_test", legacyAmplitude: true), deps: d)
        await grant(c)   // host AÇIKÇA rıza verdi
        await c.track("e")
        await c.flush()

        let _h23 = await c.stats().consent
        XCTAssertEqual(_h23, Consent(analytics: true), "taze rıza kazanır: aylar önceki Amplitude optOut bayrağı onu ezmez")
        let _h24 = await c.distinctId()
        XCTAssertEqual(_h24, "eski-id")
        let evs = await net.events.filter { $0.name == "e" }
        XCTAssertEqual(evs[0].setOnce["migrated_opt_out"], "1", "bilgi kaybolmaz")
        XCTAssertEqual(evs[0].setOnce["migrated_from"], "amplitude-sqlite")
        await c.shutdown()
    }

    func testKendiKimligimizVarkenDevralmaYenidenTetiklenmez() async {
        let net = Net()
        var d = deps(net)
        d.takeoverOverride = Takeover(deviceId: "eski-id", source: "amplitude-swift", optOut: true)
        let cfg = Configuration(writeKey: "ck_w_test", legacyAmplitude: true)

        let c1 = Core(config: cfg, deps: d)
        await grant(c1)
        let ilk = await c1.distinctId()
        XCTAssertEqual(ilk, "eski-id")
        await c1.shutdown()

        // İkinci süreç: kimlik artık KENDİ depomuzda. Devralma yeniden çalışmamalı,
        // `migrated_from`/`migrated_opt_out` ikinci kez gitmemeli.
        let c2 = Core(config: cfg, deps: d)
        await grant(c2)
        await c2.track("ikinci_surec")
        await c2.flush()
        let evs = await net.events.filter { $0.name == "ikinci_surec" }
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].setOnce, [:], "devralma işaretleri ikinci kez gönderilmez")
        XCTAssertEqual(evs[0].distinctId, "eski-id")
        await c2.shutdown()
    }

    func testLegacyAmplitudeKapaliysaDevralmaOkunmaz() async {
        let net = Net()
        var d = deps(net)
        d.takeoverOverride = Takeover(deviceId: "eski-id", source: "amplitude-sqlite", optOut: false)
        let c = Core(config: Configuration(writeKey: "ck_w_test", legacyAmplitude: false), deps: d)
        await grant(c)
        let _h25 = await c.distinctId()
        XCTAssertNotEqual(_h25, "eski-id")
        await c.shutdown()
    }

    // MARK: - 12. Yaşam döngüsü durumunun yeri (madde 10)

    func testStateURLCachesIcindeDegil() {
        for name in ["ios", "tvos", "macos"] {
            let p = Platform.make(name: name)
            let loc = Core.lifecycleLocation(platform: p, defaultsSuite: nil)
            XCTAssertFalse(loc.url.path.contains("/Caches/"),
                           "\(name): yaşam döngüsü durumu Caches'e konulamaz (sistem boşaltınca installed tekrar eder)")
            if name == "tvos" {
                XCTAssertNotEqual(loc.url.deletingLastPathComponent().path, p.queueDirectory.path,
                                  "tvOS: durum kuyruk dizininden (Caches) BAĞIMSIZ olmalı")
                XCTAssertTrue(p.queueDirectory.path.contains("/Caches/"), "tvOS kuyruğu bilerek Caches'te")
            }
        }
    }

    func testTvOSYasamDongusuDurumuUserDefaultsta() {
        XCTAssertTrue(Core.lifecycleLocation(platform: .make(name: "tvos"), defaultsSuite: nil).usesDefaults)
        XCTAssertFalse(Core.lifecycleLocation(platform: .make(name: "ios"), defaultsSuite: nil).usesDefaults)
    }

    // MARK: - 13. stats (madde 18) ve sürüm (madde 20)

    func testStatsTanilamaSayaclariniGosterir() async {
        let net = Net()
        let c = core(net, deps(net, platform: platform(flushAt: 100)))
        await grant(c)
        await c.track("e")
        let s = await c.stats()
        XCTAssertEqual(s.queued, 1)
        XCTAssertEqual(s.skipped, 0)
        XCTAssertEqual(s.rejected, 0)
        XCTAssertFalse(s.disabled)
        XCTAssertTrue(s.deviceIdAvailable)
        XCTAssertTrue(s.running)
        await c.shutdown()
    }

    func testStatsOkunamayanSatirlariSkippedOlarakGosterir() async {
        let net = Net()
        let c = core(net, deps(net, platform: platform(flushAt: 100)))
        await grant(c)
        await c.track("e")
        // Kuyruğa elle zehirli satır: Core'un gördüğü sayaç Dispatcher'ın `skippedCount()`'u olmalı.
        let f = dir.appendingPathComponent("queue.jsonl")
        let body = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        try? Data((body + "bozuk-satir\n").utf8).write(to: f)
        await c.shutdown()

        let c2 = core(net, deps(net, platform: platform(flushAt: 100)))
        await c2.start()
        await c2.flush()
        let _h26 = await c2.stats().skipped
        XCTAssertEqual(_h26, 1, "okunamayan satır stats()'ta görünür")
        await c2.shutdown()
    }

    func test401SonrasiSDKDurdurulurVeUyarilir() async {
        let net = Net { _ in (.fatal, nil) }
        let logged = LogBox()
        let cfg = Configuration(writeKey: "ck_w_bozuk", flushInterval: 30, legacyAmplitude: false,
                                logger: { [logged] m in logged.add(m) })
        let c = Core(config: cfg, deps: deps(net, platform: platform(flushAt: 100)))
        await grant(c)
        await c.track("e")
        await c.flush()
        let s = await c.stats()
        XCTAssertTrue(s.disabled, "401/403 SDK'yı durdurur")
        XCTAssertTrue(logged.contains("yazma anahtarı reddedildi"), "sessiz durmaz")
        XCTAssertEqual(s.queued, 1, "durdurulan SDK kuyruğu SİLMEZ")
        await c.shutdown()
    }

    func testLibVersionSurumKaynagiylaAyni() throws {
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        let raw = try? String(contentsOf: versionFile, encoding: .utf8)
        try XCTSkipIf(raw == nil, "VERSION dosyası yalnız depo içinde var")
        XCTAssertEqual(Cizeylem.version, raw?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testContextLibVersionTasir() async {
        let net = Net()
        let c = core(net)
        await grant(c)
        await c.track("e")
        await c.flush()
        let evs = await net.events.filter { $0.name == "e" }
        XCTAssertEqual(evs[0].context["lib_version"], Cizeylem.version)
        await c.shutdown()
    }

    // MARK: - 14. Context tazeliği (madde 13)

    func testContextHerEventteYenidenHesaplanir() async {
        let net = Net()
        let center = NotificationCenter()
        var d = deps(net, platform: platform(flushAt: 100), freshLifecycle: true)
        d.notificationCenter = center
        let c = Core(config: config(), deps: d)
        await grant(c)
        _ = await waitUntil { await c.stats().queued >= 1 }
        await c.track("once")
        center.post(name: LifecycleObserver.backgroundName, object: nil)
        _ = await waitUntil { await c.stats().queued >= 3 }
        await c.track("sonra")
        await c.flush()

        let evs = await net.events
        let once = evs.first { $0.name == "once" }
        let sonra = evs.first { $0.name == "sonra" }
        XCTAssertEqual(once?.context["app_state"], "background", "startsActive=false → arka plan")
        XCTAssertEqual(sonra?.context["app_state"], "background")
        XCTAssertNotNil(once?.context["consent_scope"])
        await c.shutdown()
    }

    func testRizaKapsamiDegisinceContextDeDegisir() async {
        let net = Net()
        let c = core(net, deps(net, platform: platform(flushAt: 100)))
        await grant(c)
        await c.track("a")
        await c.setConsent(Consent(analytics: true, attribution: true))
        await c.track("b")
        await c.flush()
        let evs = await net.events
        XCTAssertEqual(evs.first { $0.name == "a" }?.context["consent_scope"], "analytics")
        XCTAssertEqual(evs.first { $0.name == "b" }?.context["consent_scope"], "analytics,attribution")
        await c.shutdown()
    }
}

// MARK: - Küçük test kutuları

/// Dosya destekli kilit bayrağı: `@Sendable` kapanımdan okunur, `@unchecked` gerekmez.
private final class LockBox: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cz-lock-\(UUID().uuidString)")

    init() { try? Data("1".utf8).write(to: url) }
    deinit { try? FileManager.default.removeItem(at: url) }

    var isLocked: Bool { (try? Data(contentsOf: url)) == Data("1".utf8) }
    func unlock() { try? Data("0".utf8).write(to: url) }
}

/// Logger çıktısını toplayan kutu (dosya destekli, kilitsiz).
private final class LogBox: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cz-log-\(UUID().uuidString)")

    init() { try? Data().write(to: url) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func add(_ message: String) {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? Data((old + message + "\n").utf8).write(to: url)
    }

    func contains(_ needle: String) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(needle)
    }
}

/// Sırayla UUID veren kutu (dosya destekli, kilitsiz).
private final class UUIDBox: Sendable {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cz-uuid-\(UUID().uuidString)")
    private let values: [String]

    init(_ values: [String]) {
        self.values = values
        try? Data("0".utf8).write(to: url)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func next() -> String {
        let i = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0) } ?? 0
        try? Data(String(i + 1).utf8).write(to: url)
        return i < values.count ? values[i] : UUID().uuidString
    }
}

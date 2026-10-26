import XCTest
@testable import Cizeylem

/// Test tarafı kayıt kutusu. `onEvent`/`onBackground` kapanımları eşzamanlı ve `@Sendable`; değişebilir
/// durum `@unchecked` kaçışı olmadan bir `AsyncStream` + aktörle taşınır (sıra korunur).
private struct LifeEv: Sendable, Equatable {
    var name: String
    var props: [String: String]
    var onMain: Bool
}

private actor LifeLog {
    private(set) var items: [LifeEv] = []
    func add(_ s: LifeEv) { items.append(s) }
}

private final class LifeSink: Sendable {
    let log = LifeLog()
    private let continuation: AsyncStream<LifeEv>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<LifeEv>.makeStream()
        self.continuation = continuation
        let log = log
        Task.detached { for await s in stream { await log.add(s) } }
    }

    deinit { continuation.finish() }

    var onEvent: @Sendable (String, [String: Any]) -> Void {
        { [continuation] name, props in
            continuation.yield(LifeEv(name: name, props: props.mapValues { "\($0)" }, onMain: Thread.isMainThread))
        }
    }

    var onBackground: @Sendable () -> Void {
        { [continuation] in continuation.yield(LifeEv(name: "FLUSH", props: [:], onMain: Thread.isMainThread)) }
    }

    /// En az `count` kayıt gelene kadar (en çok ~3 sn) bekler, sonra hepsini döner.
    func wait(_ count: Int) async -> [LifeEv] {
        for _ in 0..<300 {
            let items = await log.items
            if items.count >= count { return items }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await log.items
    }

    /// Yeni bir şey gelmediğini kanıtlamak için kısa süre bekler.
    func settle() async -> [LifeEv] {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return await log.items
    }

    func names(_ count: Int) async -> [String] { await wait(count).map(\.name) }
}

final class LifecycleObserverTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path)
            try? FileManager.default.removeItem(at: d)
        }
        dirs = []
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cz-life-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    private func stateURL() -> URL { tempDir().appendingPathComponent("lifecycle") }

    private func make(
        _ center: NotificationCenter, _ url: URL, _ sink: LifeSink,
        version: String? = "1.0", build: String? = "10",
        existing: Bool = false, startsActive: Bool = false,
        defaults: String? = nil
    ) -> LifecycleObserver {
        LifecycleObserver(
            notificationCenter: center, stateURL: url, app: AppInfo(version: version, build: build),
            existingInstall: existing, startsActive: startsActive,
            usesDefaults: defaults != nil, defaultsSuite: defaults,
            onEvent: sink.onEvent, onBackground: sink.onBackground)
    }

    private func active(_ c: NotificationCenter) { c.post(name: LifecycleObserver.activeName, object: nil) }
    private func background(_ c: NotificationCenter) { c.post(name: LifecycleObserver.backgroundName, object: nil) }

    // MARK: - Kurulum

    func testIlkAcilistaInstalledGonderilirSonraOpened() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink)
        o.start()
        active(c)
        let items = await sink.wait(2)
        XCTAssertEqual(items.map(\.name), ["cz_app_installed", "cz_app_opened"])
        XCTAssertEqual(items.first?.props, ["existing_install": "false"])
        withExtendedLifetime(o) {}
    }

    func testDevralmaVarsaExistingInstallTrue() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink, existing: true)
        o.start()
        let items = await sink.wait(1)
        XCTAssertEqual(items.first?.props, ["existing_install": "true"])
        withExtendedLifetime(o) {}
    }

    func testIkinciAcilistaInstalledYokOpenedVar() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1)
        o1.start(); active(c1)
        _ = await s1.wait(2)

        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2)
        o2.start(); active(c2)
        let items = await s2.wait(1)
        XCTAssertEqual(items.map(\.name), ["cz_app_opened"])
        let after = await s2.settle()
        XCTAssertEqual(after.map(\.name), ["cz_app_opened"])
        withExtendedLifetime((o1, o2)) {}
    }

    func testSurumDegisinceUpdatedOncekiSurumVeBuildIleGonderilir() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: "1.0", build: "10")
        o1.start()
        _ = await s1.wait(1)

        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: "1.1", build: "11")
        o2.start(); active(c2)
        let items = await s2.wait(2)
        XCTAssertEqual(items.map(\.name), ["cz_app_updated", "cz_app_opened"])
        XCTAssertEqual(items.first?.props, ["previous_version": "1.0", "previous_build": "10"])

        // Durum ilerledi: aynı sürümle bir sonraki açılışta tekrar yok.
        let c3 = NotificationCenter(), s3 = LifeSink()
        let o3 = make(c3, url, s3, version: "1.1", build: "11")
        o3.start()
        let again = await s3.settle()
        XCTAssertTrue(again.isEmpty)
        withExtendedLifetime((o1, o2, o3)) {}
    }

    func testSadeceBuildDegisinceUpdated() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: "1.0", build: "10")
        o1.start(); _ = await s1.wait(1)
        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: "1.0", build: "11")
        o2.start()
        let items = await s2.wait(1)
        XCTAssertEqual(items.first?.name, "cz_app_updated")
        XCTAssertEqual(items.first?.props, ["previous_version": "1.0", "previous_build": "10"])
        withExtendedLifetime((o1, o2)) {}
    }

    /// Karar 4: `updated` "sürüm değişti"dir, yön değil; düşürme de sayılır (Android ile parity).
    func testSurumDusurmeDeUpdatedSayilir() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: "2.0", build: "20")
        o1.start(); _ = await s1.wait(1)
        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: "1.9", build: "19")
        o2.start()
        let items = await s2.wait(1)
        XCTAssertEqual(items.first?.name, "cz_app_updated")
        XCTAssertEqual(items.first?.props, ["previous_version": "2.0", "previous_build": "20"])
        withExtendedLifetime((o1, o2)) {}
    }

    func testOncekiBuildYoksaPreviousBuildYazilmaz() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: "1.0", build: nil)
        o1.start(); _ = await s1.wait(1)
        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: "1.1", build: "11")
        o2.start()
        let items = await s2.wait(1)
        XCTAssertEqual(items.first?.props, ["previous_version": "1.0"])
        withExtendedLifetime((o1, o2)) {}
    }

    // MARK: - Karar 1: yazma hatası

    func testYazilamazDurumdaInstalledTekrarlanmaz() async throws {
        // Salt okunur dizin: durum dosyası yok (ENOENT, yani "ilk açılış") ama yazılamıyor.
        let dir = tempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("sub/lifecycle")

        var all: [String] = []
        for _ in 0..<3 {
            let c = NotificationCenter(), sink = LifeSink()
            let o = make(c, url, sink)
            o.start(); active(c)
            let items = await sink.wait(1)
            _ = await sink.settle()
            all += await sink.log.items.map(\.name)
            withExtendedLifetime(o) {}
            XCTAssertFalse(items.isEmpty)
        }
        XCTAssertEqual(all.filter { $0 == "cz_app_installed" }.count, 1, "\(all)")
        XCTAssertEqual(all.filter { $0 == "cz_app_opened" }.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testYazilamazDurumdaUpdatedTekrarlanmaz() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("lifecycle")
        let c0 = NotificationCenter(), s0 = LifeSink()
        let o0 = make(c0, url, s0, version: "1.0", build: "10")
        o0.start(); _ = await s0.wait(1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        var updated = 0
        for _ in 0..<3 {
            let c = NotificationCenter(), sink = LifeSink()
            let o = make(c, url, sink, version: "1.1", build: "11")
            o.start()
            _ = await sink.wait(1)
            updated += await sink.settle().filter { $0.name == "cz_app_updated" }.count
            withExtendedLifetime(o) {}
        }
        XCTAssertEqual(updated, 1)
        withExtendedLifetime(o0) {}
    }

    // MARK: - Karar 2: opened

    func testArkaPlanOnPlanDizisindeHicOpenedYutulmaz() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink)
        o.start()
        active(c); background(c); active(c); background(c); active(c)
        let names = await sink.names(1 + 5)
        XCTAssertEqual(names, [
            "cz_app_installed", "cz_app_opened",
            "cz_app_backgrounded", "FLUSH",
            "cz_app_opened",
            "cz_app_backgrounded", "FLUSH",
            "cz_app_opened",
        ].prefix(names.count).map { $0 })
        let all = await sink.settle()
        XCTAssertEqual(all.filter { $0.name == "cz_app_opened" }.count, 3)
        XCTAssertEqual(all.filter { $0.name == "cz_app_backgrounded" }.count, 2)
        XCTAssertEqual(all.filter { $0.name == "FLUSH" }.count, 2)
        withExtendedLifetime(o) {}
    }

    /// Kontrol merkezi kapanışı: arka plan görmeden gelen ikinci `didBecomeActive` yeni açılış değildir,
    /// ve bu, sonraki gerçek açılışı yutmaz.
    func testArkaPlansizTekrarActiveOpenedUretmezAmaSonrakiGercekAcilisiYutmaz() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink)
        o.start()
        active(c); active(c); active(c)
        _ = await sink.wait(2)
        var all = await sink.settle()
        XCTAssertEqual(all.filter { $0.name == "cz_app_opened" }.count, 1)
        background(c); active(c)
        all = await sink.wait(5)
        XCTAssertEqual(all.filter { $0.name == "cz_app_opened" }.count, 2)
        withExtendedLifetime(o) {}
    }

    /// SDK ön plandayken kurulduysa `didBecomeActive` kaçmıştır; ilk opened yine üretilir ve sonraki
    /// arka plan yutulmaz.
    func testOnPlandaKurulursaOpenedUretilirVeSonrakiArkaPlanYutulmaz() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink, startsActive: true)
        o.start()
        var items = await sink.wait(2)
        XCTAssertEqual(items.map(\.name), ["cz_app_installed", "cz_app_opened"])
        active(c) // gecikmiş/ikinci bildirim çift saymaz
        background(c); active(c)
        items = await sink.wait(5)
        XCTAssertEqual(items.map(\.name), [
            "cz_app_installed", "cz_app_opened", "cz_app_backgrounded", "FLUSH", "cz_app_opened"])
        withExtendedLifetime(o) {}
    }

    /// Faz bilinmezken (kurulum sonrası ilk bildirim arka plansa) arka plan yine olay ve flush üretir.
    func testIlkBildirimArkaPlansaBackgroundedVeFlushUretilir() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink)
        o.start()
        background(c)
        let names = await sink.names(3)
        XCTAssertEqual(names, ["cz_app_installed", "cz_app_backgrounded", "FLUSH"])
        withExtendedLifetime(o) {}
    }

    func testArkaPlanaGecinceBackgroundedVeFlushTetiklenir() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink)
        o.start(); active(c)
        _ = await sink.wait(2)
        background(c)
        let items = await sink.wait(4)
        XCTAssertEqual(items.suffix(2).map(\.name), ["cz_app_backgrounded", "FLUSH"])
        withExtendedLifetime(o) {}
    }

    // MARK: - Karar 3: rızasız iz yok

    func testStartOncesiHicIzVeEventYok() async {
        let url = stateURL()
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, url, sink)
        active(c); background(c)
        let items = await sink.settle()
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path + "/lifecycle"))
        withExtendedLifetime(o) {}
    }

    func testStartYazmadanOnceDizinDeYaratilmaz() async {
        let url = tempDir().appendingPathComponent("yok/lifecycle")
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, url, sink)
        _ = await sink.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        withExtendedLifetime(o) {}
    }

    // MARK: - Karar 5: sürüm okunamıyor

    func testSurumOkunamazsaInstalledYineUretilirVeTekrarlanmaz() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: nil, build: nil)
        o1.start()
        let first = await s1.wait(1)
        XCTAssertEqual(first.map(\.name), ["cz_app_installed"])

        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: nil, build: nil)
        o2.start()
        let second = await s2.settle()
        XCTAssertTrue(second.isEmpty)
        withExtendedLifetime((o1, o2)) {}
    }

    func testSurumOkunamazsaBilinenSurumSilinmezVeUpdatedUretilmez() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: "1.0", build: "10")
        o1.start(); _ = await s1.wait(1)

        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: nil, build: nil)
        o2.start()
        let none = await s2.settle()
        XCTAssertTrue(none.isEmpty)

        // Sürüm geri geldi ve aynı: kayıt korunduğu için updated yok.
        let c3 = NotificationCenter(), s3 = LifeSink()
        let o3 = make(c3, url, s3, version: "1.0", build: "10")
        o3.start()
        let same = await s3.settle()
        XCTAssertTrue(same.isEmpty)
        withExtendedLifetime((o1, o2, o3)) {}
    }

    func testOncekiSurumBilinmiyorsaUpdatedUretilmezAmaKaydedilir() async {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: nil, build: nil)
        o1.start(); _ = await s1.wait(1)
        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: "1.0", build: "10")
        o2.start()
        let quiet = await s2.settle()
        XCTAssertTrue(quiet.isEmpty)
        let c3 = NotificationCenter(), s3 = LifeSink()
        let o3 = make(c3, url, s3, version: "1.1", build: "11")
        o3.start()
        let items = await s3.wait(1)
        XCTAssertEqual(items.first?.props, ["previous_version": "1.0", "previous_build": "10"])
        withExtendedLifetime((o1, o2, o3)) {}
    }

    // MARK: - Bozuk / okunamayan durum

    func testBozukDurumdaInstalledUretilmezVeKayitYenilenir() async throws {
        let url = stateURL()
        try Data("{kesik".utf8).write(to: url)
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, url, sink)
        o.start()
        let quiet = await sink.settle()
        XCTAssertTrue(quiet.isEmpty)
        XCTAssertEqual(LifecycleStateStore(url: url, usesDefaults: false, defaultsSuite: nil).load(),
                       .value(LifecycleSnapshot(version: "1.0", build: "10")))
        withExtendedLifetime(o) {}
    }

    /// Okuma hatası (burada: yol bir dizin) "yok" sayılmaz: sahte installed üretilmez, üzerine yazılmaz.
    func testOkunamayanDurumdaInstalledUretilmezVeYazilmaz() async {
        let url = tempDir().appendingPathComponent("lifecycle")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, url, sink)
        o.start(); active(c)
        let items = await sink.wait(1)
        XCTAssertEqual(items.map(\.name), ["cz_app_opened"])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
        withExtendedLifetime(o) {}
    }

    // MARK: - tvOS

    func testTvOSDurumuUserDefaultsteTutulurDosyaYazilmaz() async {
        let suite = "cz-life-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, defaults: suite)
        o1.start()
        let first = await s1.names(1)
        XCTAssertEqual(first, ["cz_app_installed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(UserDefaults(suiteName: suite)?.string(forKey: LifecycleStateStore.defaultsKey))

        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: "1.1", build: "11", defaults: suite)
        o2.start()
        let items = await s2.wait(1)
        XCTAssertEqual(items.map(\.name), ["cz_app_updated"])
        withExtendedLifetime((o1, o2)) {}
    }

    // MARK: - Yaşam süresi, thread

    func testStartIkiKezCagrilirsaOlayCiftlenmez() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink, startsActive: true)
        o.start(); o.start()
        active(c); background(c); active(c)
        _ = await sink.wait(5)
        let all = await sink.settle()
        XCTAssertEqual(all.map(\.name), [
            "cz_app_installed", "cz_app_opened", "cz_app_backgrounded", "FLUSH", "cz_app_opened"])
        withExtendedLifetime(o) {}
    }

    /// Başarılı yazımdan sonra durum bellekten değil diskten okunur: dışarıdan değişen kayıt görülür.
    func testBasariliYazimdanSonraDiskinGercekDurumuKullanilir() async throws {
        let url = stateURL()
        let c1 = NotificationCenter(), s1 = LifeSink()
        let o1 = make(c1, url, s1, version: "1.0", build: "10")
        o1.start(); _ = await s1.wait(1)
        try Data(#"{"build":"9","version":"0.9"}"#.utf8).write(to: url)
        let c2 = NotificationCenter(), s2 = LifeSink()
        let o2 = make(c2, url, s2, version: "1.0", build: "10")
        o2.start()
        let items = await s2.wait(1)
        XCTAssertEqual(items.first?.props, ["previous_version": "0.9", "previous_build": "9"])
        withExtendedLifetime((o1, o2)) {}
    }

    /// Okunamayan (izinsiz) ama yazılabilir dizindeki kayıt: karar verilmez ve ÜZERİNE YAZILMAZ.
    func testIzinsizKayitliDosyaUzerineYazilmaz() async throws {
        let url = stateURL()
        let original = Data(#"{"build":"10","version":"1.0"}"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, url, sink, version: "2.0", build: "20")
        o.start()
        let items = await sink.settle()
        XCTAssertTrue(items.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
        withExtendedLifetime(o) {}
    }

    func testDurumDosyasiYedekttenHaricTutulur() async throws {
        let url = stateURL()
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, url, sink)
        o.start(); _ = await sink.wait(1)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        withExtendedLifetime(o) {}
    }

    func testGozlemciBirakilinceAbonelikTemizlenirGecBildirimCokmez() async {
        let c = NotificationCenter(), sink = LifeSink()
        var o: LifecycleObserver? = make(c, stateURL(), sink)
        o?.start(); active(c)
        _ = await sink.wait(2)
        o = nil
        active(c); background(c); active(c)
        let all = await sink.settle()
        XCTAssertEqual(all.map(\.name), ["cz_app_installed", "cz_app_opened"])
    }

    /// Tüketici görev bırakılan gözlemciyle birlikte biter ve kapanımları serbest bırakır (sızıntı yok).
    func testGozlemciBirakilinceKapanimlarSerbestKalir() async {
        final class Sentinel: Sendable {}
        let weakRef: WeakBox
        do {
            let sentinel = Sentinel()
            weakRef = WeakBox(sentinel)
            let c = NotificationCenter()
            var o: LifecycleObserver? = LifecycleObserver(
                notificationCenter: c, stateURL: stateURL(), app: AppInfo(version: "1", build: "1"),
                usesDefaults: false,
                onEvent: { _, _ in _ = sentinel }, onBackground: { _ = sentinel })
            o?.start()
            o = nil
        }
        for _ in 0..<200 where weakRef.alive { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(weakRef.alive)
    }

    @MainActor
    func testAnaThreaddeGelenBildirimDiskIsiVeEventAnaThreaddeYapilmaz() async {
        let c = NotificationCenter(), sink = LifeSink()
        let o = make(c, stateURL(), sink)
        o.start()
        active(c); background(c)
        let items = await sink.wait(4)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { !$0.onMain }, "\(items)")
        withExtendedLifetime(o) {}
    }
}

private final class WeakBox {
    private weak var value: AnyObject?
    init(_ v: AnyObject) { value = v }
    var alive: Bool { value != nil }
}

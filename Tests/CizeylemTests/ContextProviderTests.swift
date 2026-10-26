import XCTest
@testable import Cizeylem

final class ContextProviderTests: XCTestCase {

    private func platform(_ name: String) -> Platform { Platform.make(name: name) }

    private func device(pad: Bool = false, w: Double? = 390, h: Double? = 844) -> DeviceSnapshot {
        DeviceSnapshot(isPad: pad, screenWidth: w, screenHeight: h)
    }

    private let app = AppInfo(version: "2.4.1", build: "387")

    private func provider(
        _ name: String = "ios",
        device: DeviceSnapshot? = nil,
        app: AppInfo? = nil,
        install: String? = "app_store",
        network: @escaping @Sendable () -> String? = { "wifi" }
    ) -> ContextProvider {
        ContextProvider(
            libVersion: "1.2.3", platform: platform(name),
            device: device ?? self.device(), app: app ?? self.app,
            installSource: install, network: network)
    }

    private let off = Consent()
    private let all = Consent(analytics: true, attribution: true, adSharing: true)

    private func ctx(_ p: ContextProvider, consent: Consent? = nil, state: String = "foreground", att: String? = nil) -> [String: Any] {
        p.get(consent: consent ?? off, appState: state, attStatus: att)
    }

    // MARK: Plandaki sekiz test

    func testPlatformVeOsNameDogruDoldurulur() {
        let c = ctx(provider("ios"))
        XCTAssertEqual(c["platform"] as? String, "ios")
        XCTAssertEqual(c["os_name"] as? String, "iOS")
        XCTAssertEqual(c["device_type"] as? String, "mobile")
        XCTAssertEqual(c["device_manufacturer"] as? String, "Apple")
        let m = ctx(provider("macos"))
        XCTAssertEqual(m["platform"] as? String, "macos")
        XCTAssertEqual(m["os_name"] as? String, "macOS")
        XCTAssertEqual(m["device_type"] as? String, "desktop")
    }

    func testiPadIdiomTabletVerir() {
        let c = ctx(provider("ios", device: device(pad: true)))
        XCTAssertEqual(c["os_name"] as? String, "iPadOS")
        XCTAssertEqual(c["device_type"] as? String, "tablet")
        XCTAssertEqual(c["platform"] as? String, "ios")
    }

    func testTvOSPlatformuTvDeviceTypeVerir() {
        let c = ctx(provider("tvos", device: device(w: 1920, h: 1080)))
        XCTAssertEqual(c["platform"] as? String, "tvos")
        XCTAssertEqual(c["os_name"] as? String, "tvOS")
        XCTAssertEqual(c["device_type"] as? String, "tv")
    }

    func testAttStatusNilIseAlanYazilmaz() {
        XCTAssertNil(ctx(provider(), att: nil)["att_status"])
        XCTAssertEqual(ctx(provider(), att: "denied")["att_status"] as? String, "denied")
    }

    func testConsentScopeYalnizcaVerilenAnahtarlariIcerir() {
        XCTAssertEqual(ctx(provider(), consent: Consent(analytics: true))["consent_scope"] as? String, "analytics")
        XCTAssertEqual(ctx(provider(), consent: Consent(attribution: true, adSharing: true))["consent_scope"] as? String, "attribution,adSharing")
        XCTAssertEqual(ctx(provider(), consent: all)["consent_scope"] as? String, "analytics,attribution,adSharing")
    }

    func testConsentScopeBosIseAlanYazilmaz() {
        XCTAssertNil(ctx(provider(), consent: off)["consent_scope"])
    }

    func testLibAlaniBirIosVeLibVersionPaketten() {
        let c = ctx(provider())
        XCTAssertEqual(c["lib"] as? String, "bir-ios")
        XCTAssertEqual(c["lib_version"] as? String, "1.2.3")
    }

    func testAcilisSuresiVeDiskAlaniAlanlariHicGonderilmez() {
        for name in ["ios", "tvos", "macos"] {
            let keys = Set(ctx(provider(name), consent: all, att: "authorized").keys)
            for k in keys {
                let l = k.lowercased()
                XCTAssertFalse(l.contains("boot") || l.contains("uptime") || l.contains("disk") || l.contains("storage") || l.contains("free"), "\(name): \(k)")
            }
        }
    }

    func testEkranOlculeriPtVeDogalYone() {
        let c = ctx(provider("ios", device: device(w: 390, h: 844)))
        XCTAssertEqual(c["screen_width"] as? Double, 390)
        XCTAssertEqual(c["screen_height"] as? Double, 844)
    }

    // MARK: Ekran normalizasyonu

    func testEkranYonDegisimindeDegismezIOS() {
        // Yatay okunmuş değerler (844x390) doğal dikey yöne çevrilir.
        let a = ctx(provider("ios", device: device(w: 390, h: 844)))
        let b = ctx(provider("ios", device: device(w: 844, h: 390)))
        XCTAssertEqual(a["screen_width"] as? Double, b["screen_width"] as? Double)
        XCTAssertEqual(a["screen_height"] as? Double, b["screen_height"] as? Double)
        XCTAssertEqual(b["screen_width"] as? Double, 390)
        XCTAssertEqual(b["screen_height"] as? Double, 844)
    }

    func testEkranDogalYonTvOSVeMacOSYataydir() {
        for name in ["tvos", "macos"] {
            let a = ctx(provider(name, device: device(w: 1920, h: 1080)))
            let b = ctx(provider(name, device: device(w: 1080, h: 1920)))
            XCTAssertEqual(a["screen_width"] as? Double, 1920, name)
            XCTAssertEqual(b["screen_width"] as? Double, 1920, name)
            XCTAssertEqual(b["screen_height"] as? Double, 1080, name)
        }
    }

    func testEkranOlcusuYoksaAlanlarYazilmaz() {
        let c = ctx(provider("macos", device: device(w: nil, h: nil)))
        XCTAssertNil(c["screen_width"])
        XCTAssertNil(c["screen_height"])
    }

    func testYalnizBirEkranOlcusuVarsaIkisiDeYazilmaz() {
        for d in [device(w: 390, h: nil), device(w: nil, h: 844)] {
            let c = ctx(provider(device: d))
            XCTAssertNil(c["screen_width"])
            XCTAssertNil(c["screen_height"])
        }
    }

    // MARK: Ağ

    func testNetworkTypeKaynaktanGelir() {
        for v in ["wifi", "cellular", "ethernet", "offline", "other"] {
            XCTAssertEqual(ctx(provider(network: { v }))["network_type"] as? String, v)
        }
    }

    func testBilinmeyenAgDurumundaAlanYazilmaz() {
        let monitor = NetworkMonitor(autostart: false)
        XCTAssertFalse(monitor.isKnown)
        XCTAssertNil(monitor.current)
        XCTAssertNil(ctx(provider(network: { monitor.current }))["network_type"])
        XCTAssertNil(ctx(provider(network: { nil }))["network_type"])
    }

    func testOtherBilinenAmaSiniflanmayanTasimaIcinYazilir() {
        XCTAssertEqual(ctx(provider(network: { "other" }))["network_type"] as? String, "other")
        XCTAssertEqual(NetworkMonitor.classify(satisfied: true, wifi: false, cellular: false, wired: false), "other")
    }

    /// Monitör açıkken bırakılır; güncelleme uçuştayken `deinit` çalışır. Semafor/grup dengesizliği
    /// libdispatch çökmesi olarak görünürdü.
    func testMonitorUcusIcindeGuncellemeVarkenBirakilabilir() {
        for i in 0..<300 {
            var m: NetworkMonitor? = NetworkMonitor()
            if i % 3 == 0 { _ = m?.current }
            if i % 3 == 1 { Thread.sleep(forTimeInterval: 0.001) }
            m = nil
        }
        let m = NetworkMonitor()
        let deadline = Date().addingTimeInterval(5)
        while !m.isKnown && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(m.isKnown)
        XCTAssertTrue(m.isKnown)
    }

    func testAgSiniflandirmasi() {
        XCTAssertEqual(NetworkMonitor.classify(satisfied: false, wifi: true, cellular: true, wired: true), "offline")
        XCTAssertEqual(NetworkMonitor.classify(satisfied: true, wifi: true, cellular: true, wired: true), "wifi")
        XCTAssertEqual(NetworkMonitor.classify(satisfied: true, wifi: false, cellular: true, wired: true), "cellular")
        XCTAssertEqual(NetworkMonitor.classify(satisfied: true, wifi: false, cellular: false, wired: true), "ethernet")
        XCTAssertEqual(NetworkMonitor.classify(satisfied: true, wifi: false, cellular: false, wired: false), "other")
    }

    func testGercekMonitorIlkGuncellemedenSonraBilinirOlur() {
        let monitor = NetworkMonitor()
        let deadline = Date().addingTimeInterval(5)
        while !monitor.isKnown && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(monitor.isKnown)
        XCTAssertTrue(["wifi", "cellular", "ethernet", "offline", "other"].contains(monitor.current ?? "yok"))
    }

    // MARK: install_source

    func testInstallSourceTuretme() {
        XCTAssertEqual(InstallSource.derive(receiptName: "sandboxReceipt", receiptExists: true, isSimulator: false), "testflight")
        XCTAssertEqual(InstallSource.derive(receiptName: "sandboxReceipt", receiptExists: false, isSimulator: false), "testflight")
        XCTAssertEqual(InstallSource.derive(receiptName: "receipt", receiptExists: true, isSimulator: false), "app_store")
        XCTAssertNil(InstallSource.derive(receiptName: "receipt", receiptExists: false, isSimulator: false))
        XCTAssertNil(InstallSource.derive(receiptName: nil, receiptExists: false, isSimulator: false))
        XCTAssertNil(InstallSource.derive(receiptName: "baska", receiptExists: true, isSimulator: false))
        XCTAssertEqual(InstallSource.derive(receiptName: "sandboxReceipt", receiptExists: true, isSimulator: true), "dev")
        XCTAssertEqual(InstallSource.derive(receiptName: nil, receiptExists: false, isSimulator: true), "dev")
    }

    func testInstallSourceYoksaAlanYazilmaz() {
        XCTAssertNil(ctx(provider(install: nil))["install_source"])
        XCTAssertEqual(ctx(provider(install: "testflight"))["install_source"] as? String, "testflight")
    }

    // MARK: Diğer alanlar

    func testUygulamaSurumuVeBuild() {
        let c = ctx(provider())
        XCTAssertEqual(c["app_version"] as? String, "2.4.1")
        XCTAssertEqual(c["app_build"] as? String, "387")
        let n = ctx(provider(app: AppInfo(version: nil, build: nil)))
        XCTAssertNil(n["app_version"])
        XCTAssertNil(n["app_build"])
    }

    func testAppStateHerCagridaTazelenir() {
        let p = provider()
        XCTAssertEqual(ctx(p, state: "foreground")["app_state"] as? String, "foreground")
        XCTAssertEqual(ctx(p, state: "background")["app_state"] as? String, "background")
    }

    func testDegisebilenAlanlarHerCagridaTazelenir() {
        let p = provider()
        XCTAssertEqual(ctx(p, consent: Consent(analytics: true), att: "denied")["att_status"] as? String, "denied")
        XCTAssertNil(ctx(p, consent: off, att: nil)["att_status"])
        XCTAssertEqual(ctx(p, consent: all)["consent_scope"] as? String, "analytics,attribution,adSharing")
        XCTAssertNil(ctx(p, consent: off)["consent_scope"])
    }

    func testNetworkTypeHerCagridaTazelenir() {
        let box = Counter()
        let p = provider(network: { box.next() })
        XCTAssertEqual(ctx(p)["network_type"] as? String, "wifi")
        XCTAssertEqual(ctx(p)["network_type"] as? String, "cellular")
    }

    func testLocaleVeTimezoneDoludurVeBcp47() {
        let c = ctx(provider())
        let locale = c["locale"] as? String
        XCTAssertNotNil(locale)
        XCTAssertFalse(locale!.contains("_"))
        XCTAssertFalse(locale!.contains("@"))
        XCTAssertFalse((c["timezone"] as? String ?? "").isEmpty)
    }

    func testTimezoneSistemSaatDilimidir() {
        XCTAssertEqual(ctx(provider())["timezone"] as? String, TimeZone.autoupdatingCurrent.identifier)
    }

    func testBcp47Donusumu() {
        XCTAssertEqual(ContextProvider.bcp47("tr_TR"), "tr-TR")
        XCTAssertEqual(ContextProvider.bcp47("tr_TR@calendar=gregorian"), "tr-TR")
        XCTAssertEqual(ContextProvider.bcp47("en"), "en")
        XCTAssertEqual(ContextProvider.bcp47("zh_Hans_CN"), "zh-Hans-CN")
    }

    func testOsVersionBicimiPatchSifirsaYazilmaz() {
        XCTAssertEqual(ContextProvider.formatOSVersion(OperatingSystemVersion(majorVersion: 17, minorVersion: 2, patchVersion: 0)), "17.2")
        XCTAssertEqual(ContextProvider.formatOSVersion(OperatingSystemVersion(majorVersion: 17, minorVersion: 2, patchVersion: 1)), "17.2.1")
    }

    func testSimulatorOrtamindanModelKodu() {
        XCTAssertEqual(DeviceModel.identifier(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone17,3"]), "iPhone17,3")
        XCTAssertNotEqual(DeviceModel.identifier(environment: ["SIMULATOR_MODEL_IDENTIFIER": ""]), "")
    }

    #if os(macOS)
    func testMacOSModelKoduMimariDegildir() {
        let m = DeviceModel.identifier(environment: [:])
        XCTAssertNotEqual(m, "arm64")
        XCTAssertNotEqual(m, "x86_64")
        XCTAssertTrue(m.hasPrefix("Mac") || m.contains(","), m)
    }
    #endif

    func testOsVersionNoktaliSurum() {
        let v = ctx(provider())["os_version"] as? String ?? ""
        XCTAssertTrue(v.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil, v)
    }

    func testDeviceModelHamKodDolu() {
        let m = ctx(provider())["device_model"] as? String ?? ""
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(m, DeviceModel.identifier)
    }

    func testUcPlatformunAlanKumeleriAynidir() {
        let expected: Set<String> = [
            "platform", "app_version", "os_name", "os_version", "device_model", "device_type",
            "locale", "timezone", "screen_width", "screen_height",
            "lib", "lib_version", "app_build", "device_manufacturer", "network_type",
            "install_source", "app_state", "att_status", "consent_scope",
        ]
        for name in ["ios", "tvos", "macos"] {
            let keys = Set(ctx(provider(name), consent: all, att: "authorized").keys)
            XCTAssertEqual(keys, expected, name)
        }
    }

    func testPadIdiomuYalnizIOSteTabletVerir() {
        // iPad idiom'u tvOS/macOS'ta anlamsızdır; platform önce gelir.
        XCTAssertEqual(ctx(provider("tvos", device: device(pad: true)))["device_type"] as? String, "tv")
        XCTAssertEqual(ctx(provider("macos", device: device(pad: true)))["device_type"] as? String, "desktop")
        XCTAssertEqual(ctx(provider("macos", device: device(pad: true)))["os_name"] as? String, "macOS")
    }

    // MARK: Ana thread kuralı (karar 2)

    // Asıl güvence derleyicidir: `get()` nonisolated, UIKit/AppKit API'leri `@MainActor`; Swift 6 modunda
    // `get()` içine `UIScreen`/`UIDevice` çağrısı eklenirse derleme hatası verir. Aşağıdaki testler
    // çalışma zamanı davranışını tamamlar, derleyici güvencesinin yerini tutmaz.

    func testGetEszamanliGorevlerdenCalisir() async {
        let p = provider()
        let results = await withTaskGroup(of: [String: String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let c = p.get(consent: Consent(analytics: true), appState: "foreground", attStatus: nil)
                    return ["p": c["platform"] as? String ?? "", "w": "\(c["screen_width"] as? Double ?? 0)"]
                }
            }
            var out: [[String: String]] = []
            for await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0["p"] == "ios" && $0["w"] == "390.0" })
    }

    /// Ana kuyruk gerçekten bloke: bir blok ana thread'i 1,5 sn uyutuyor. `get()` ana thread'e sıçrasa
    /// (`DispatchQueue.main.sync`) o blok bitene kadar beklerdi ve süre sınırı aşılırdı.
    func testGetAnaKuyrukBlokeIkenArkaPlandaHizlaBiter() {
        let p = provider()
        let mainBlocked = DispatchSemaphore(value: 0)
        let done = expectation(description: "get bitti")
        DispatchQueue.main.async {
            mainBlocked.signal()
            Thread.sleep(forTimeInterval: 1.5)
        }
        Thread.detachNewThread {
            XCTAssertFalse(Thread.isMainThread)
            mainBlocked.wait()
            let start = Date()
            _ = p.get(consent: Consent(analytics: true), appState: "background", attStatus: "denied")
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.75, "get() ana kuyruğu bekledi")
            done.fulfill()
        }
        // wait(for:) ana run loop'u döndürür; yukarıdaki uyku bloğu burada ana thread'i gerçekten tutar.
        wait(for: [done], timeout: 10)
    }

    @MainActor
    func testKurulumAnindaAnaAktordaYakalamaCalisir() {
        let p = ContextProvider(libVersion: "1.0.0", platform: Platform.make(name: "macos"))
        let c = p.get(consent: off, appState: "foreground", attStatus: nil)
        XCTAssertEqual(c["lib"] as? String, "bir-ios")
        XCTAssertNotNil(c["device_model"])
    }
}

/// Çağrı sayısını bir dosyada tutar: kaçış anotasyonu olmadan Sendable kalmanın en düz yolu.
private final class Counter: Sendable {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("cz-ctx-counter-\(UUID().uuidString)")
    func next() -> String {
        let n = (try? String(contentsOf: url, encoding: .utf8)).flatMap(Int.init) ?? 0
        try? String(n + 1).write(to: url, atomically: true, encoding: .utf8)
        return n == 0 ? "wifi" : "cellular"
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

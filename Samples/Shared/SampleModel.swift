import Cizeylem
import Foundation
import SwiftUI

/// Örnek uygulamaların ortak durumu. Amaç gösteri değil, elle doğrulama: rızasız durumda
/// hiçbir şeyin olmadığını ekrandan okuyabilmek.
@MainActor
final class SampleModel: ObservableObject {
    @Published var analytics = false
    @Published var attribution = false
    @Published var adSharing = false
    @Published var stats = "(henüz okunmadı)"
    @Published var distinctId = "(henüz okunmadı)"
    @Published var log: [String] = []

    /// SDK uyarıları buraya düşer: yutulan bir uyarı elle denemede görünmez olurdu.
    static let shared = SampleModel()

    private var counter = 0

    func appendLog(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 40 { log.removeLast() }
    }

    /// Anahtarlar SDK'ya HER değişimde tam üçlü olarak gider; SDK'nın bellekteki rızası
    /// ekrandaki anahtarlarla aynı kalmalı, yoksa ekran yalan söyler.
    func pushConsent() {
        Cizeylem.setConsent(Consent(analytics: analytics, attribution: attribution, adSharing: adSharing))
        appendLog("setConsent(analytics=\(analytics), attribution=\(attribution), adSharing=\(adSharing))")
        scheduleRefresh()
    }

    func track() {
        counter += 1
        Cizeylem.track("sample_button_tapped", ["n": counter, "screen": "main"])
        appendLog("track(sample_button_tapped, n=\(counter))")
        scheduleRefresh()
    }

    func identify() {
        Cizeylem.identify("sample-user-1", ["plan": "demo"])
        appendLog("identify(sample-user-1)")
        scheduleRefresh()
    }

    func reset() {
        Cizeylem.reset()
        appendLog("reset()")
        scheduleRefresh()
    }

    func flush() {
        Cizeylem.flush()
        appendLog("flush()")
        scheduleRefresh()
    }

    func setOptOut(_ value: Bool) {
        Cizeylem.setOptOut(value)
        appendLog("setOptOut(\(value))")
        // `setOptOut` rızayı SDK içinde değiştirir; anahtarları SDK'nın cevabından yeniden oku.
        scheduleRefresh(syncToggles: true)
    }

    func scheduleRefresh(syncToggles: Bool = false) {
        Task { await refresh(syncToggles: syncToggles) }
    }

    func refresh(syncToggles: Bool = false) async {
        // Komutlar tek sıraya girer; `stats()` kendi sorgusunu sıranın arkasına koyar.
        let s = await Cizeylem.stats()
        let id = await Cizeylem.distinctId()
        if syncToggles {
            analytics = s.consent.analytics
            attribution = s.consent.attribution
            adSharing = s.consent.adSharing
        }
        distinctId = id ?? "nil (rıza yok)"
        stats = """
        running: \(s.running)
        queued: \(s.queued)  dropped: \(s.dropped)
        rejected: \(s.rejected)  skipped: \(s.skipped)
        disabled: \(s.disabled)
        deviceIdAvailable: \(s.deviceIdAvailable)
        consent: analytics=\(s.consent.analytics) attribution=\(s.consent.attribution) adSharing=\(s.consent.adSharing)
        """
    }
}

/// Ortam değişkenleriyle ezilebilir; varsayılan, üretime YANLIŞLIKLA veri gitmesin diye
/// döngü adresidir (kimsenin dinlemediği bir port: gönderim denenir, `queued` düşmez).
enum SampleConfig {
    nonisolated static func make() -> Configuration {
        let env = ProcessInfo.processInfo.environment
        let endpoint = env["CIZEYLEM_ENDPOINT"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:9")!
        return Configuration(
            writeKey: env["CIZEYLEM_WRITE_KEY"] ?? "ck_w_sample_not_a_real_key",
            endpoint: endpoint,
            flushAt: 5,
            // Logger her thread'den çağrılır; ana aktöre kuyruklanır.
            logger: { line in Task { @MainActor in SampleModel.shared.appendLog("[sdk] \(line)") } })
    }
}

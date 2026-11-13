import XCTest
@testable import CizeylemAttribution

final class TrackingStatusTests: XCTestCase {
    func testDortDurumDogruStringeEslenir() {
        // ATTrackingManager.AuthorizationStatus ham değerleri: 0 notDetermined, 1 restricted,
        // 2 denied, 3 authorized.
        XCTAssertEqual(TrackingStatus.name(forRawValue: 0), "not_determined")
        XCTAssertEqual(TrackingStatus.name(forRawValue: 1), "restricted")
        XCTAssertEqual(TrackingStatus.name(forRawValue: 2), "denied")
        XCTAssertEqual(TrackingStatus.name(forRawValue: 3), "authorized")
    }

    func testBilinmeyenHamDegerUnavailableDoner() {
        XCTAssertEqual(TrackingStatus.name(forRawValue: 4), "unavailable")
        XCTAssertEqual(TrackingStatus.name(forRawValue: 99), "unavailable")
    }

    func testATTBulunmayanPlatformdaUnavailableDoner() {
        #if os(iOS)
        XCTAssertTrue(
            ["authorized", "denied", "restricted", "not_determined"].contains(TrackingStatus.current()))
        #else
        // tvOS ve macOS: durum okunmaz.
        XCTAssertEqual(TrackingStatus.current(), "unavailable")
        #endif
    }

    func testIdfaYalnizIOSTaOkunabilir() {
        #if !os(iOS)
        XCTAssertNil(TrackingStatus.idfa())
        #endif
    }

    func testTvOSTaAdServicesTokenNilVeDurumUnavailable() {
        #if os(tvOS)
        XCTAssertEqual(AdServicesToken.read(), .unavailable)
        XCTAssertEqual(TrackingStatus.current(), "unavailable")
        #endif
    }

    func testBosTokenNilSayilir() {
        XCTAssertNil(AdServicesToken.normalize(""))
        XCTAssertNil(AdServicesToken.normalize(nil))
        XCTAssertEqual(AdServicesToken.normalize("abc"), "abc")
    }

    /// ATT izni İSTENMEZ (SPEC §5): izin isteyen çağrının adı hiçbir kaynakta geçmemeli.
    func testDurumOkunurkenIzinIstenmez() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sources.path), "kaynak ağacı bu ortamda yok")
        let symbol = ["request", "Tracking", "Authorization"].joined()
        var scanned = 0
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let f = walker?.nextObject() as? URL {
            guard f.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(text.contains(symbol), "\(f.lastPathComponent) ATT izin isteği içeriyor")
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 10, "tarama boş kaldı, test yalancı yeşil olurdu")
    }
}

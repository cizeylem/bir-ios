import Foundation

/// Platform farklarının tek durağı: `#if os(tvOS)` kodun başka yerine dağılmaz.
struct Platform: Sendable {
    let name: String
    let queueDirectory: URL
    let maxEvents: Int
    let maxBytes: Int
    let flushAt: Int

    static var current: Platform {
        #if os(tvOS)
        make(name: "tvos")
        #elseif os(macOS)
        make(name: "macos")
        #else
        make(name: "ios")
        #endif
    }

    /// Ad verilerek kurulabilir ki tvOS değerleri macOS üzerinde de test edilebilsin.
    static func make(name: String) -> Platform {
        let fm = FileManager.default
        if name == "tvos" {
            // tvOS sistemi Application Support'u kalıcı saklamaz; kalıcı olmayan Caches'e yazıp küçük tutuyoruz.
            return Platform(
                name: name,
                queueDirectory: directory(.cachesDirectory, fm),
                maxEvents: 100, maxBytes: 5 * 1024 * 1024, flushAt: 5)
        }
        return Platform(
            name: name,
            queueDirectory: directory(.applicationSupportDirectory, fm),
            maxEvents: 1000, maxBytes: 5 * 1024 * 1024, flushAt: 30)
    }

    private static func directory(_ kind: FileManager.SearchPathDirectory, _ fm: FileManager) -> URL {
        let base = fm.urls(for: kind, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("Cizeylem", isDirectory: true)
    }
}

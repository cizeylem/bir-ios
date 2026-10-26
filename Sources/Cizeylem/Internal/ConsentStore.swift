import Foundation

/// Kalıcı rıza deposu. `DeviceIdStore` ile aynı yer: iOS/macOS `<queueDirectory>/consent`,
/// tvOS `UserDefaults` (`cz_consent`).
///
/// Kayıt üç satırlık sabit metindir (`analytics=true\n…`); yinelenen anahtarı ayırt edebilmek için
/// JSON seçilmedi (ayrıştırıcılar yinelenende sessizce sonuncuyu alır).
///
/// Bilerek durumsuz ve önbelleksiz: rıza geri alındıktan sonra bayat okuma hukuken yanlış yöndür.
/// Sıcak yol önbelleği eklenirse geri almada geçersiz kılma ayrıca sınanmalıdır.
struct ConsentStore: Sendable {
    private let platform: Platform
    private let defaultsSuite: String?
    /// Okuma hatası yolunu testte sürebilmek için enjekte edilir (`DeviceIdStore` ile aynı gerekçe).
    private let readFile: @Sendable (URL) throws -> Data

    static let defaultsKey = "cz_consent"

    private static let keys = ["analytics", "attribution", "adSharing"]

    init(
        platform: Platform,
        defaultsSuite: String? = nil,
        readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.platform = platform
        self.defaultsSuite = defaultsSuite
        self.readFile = readFile
    }

    private var usesDefaults: Bool { platform.name == "tvos" }
    private var consentFile: URL { platform.queueDirectory.appendingPathComponent("consent") }
    private var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Salt okuma: dizin, dosya ya da başka hiçbir iz oluşturmaz, hiçbir şeyi düzeltmez.
    /// Eksik, bozuk, fazla, yinelenen ya da okunamayan her kayıt üç anahtar kapalı döner.
    func read() -> Consent {
        guard let raw = loadRaw(), let parsed = Self.parse(raw) else { return Consent() }
        return parsed
    }

    /// Bu depodan okunan rızaya göre kalıcı yazım kapısı.
    func allowsWrite() -> Bool { read().allowsWrite }

    /// Tümü kapalı rıza dosyayı/anahtarı **siler**: rızasız kullanıcıda bizden iz kalmaz.
    /// Yazım başarısızsa eski kaydın geçerli kalmaması için silmeyi de dener; `false` döner.
    @discardableResult
    func write(_ consent: Consent) -> Bool {
        if consent == Consent() { return remove() }
        let text = Self.encode(consent)
        if usesDefaults {
            defaults.set(text, forKey: Self.defaultsKey)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: consentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: consentFile, options: .atomic)
            var url = consentFile
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            _ = remove()
            return false
        }
    }

    // MARK: - Depo

    private func loadRaw() -> String? {
        if usesDefaults { return defaults.string(forKey: Self.defaultsKey) }
        guard let data = try? readFile(consentFile) else { return nil }
        // `String(data:encoding:)` baştaki BOM'u sessizce atar; bizim yazmadığımız bir kayıt kapalı okunur.
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func remove() -> Bool {
        if usesDefaults {
            defaults.removeObject(forKey: Self.defaultsKey)
            return true
        }
        do {
            try FileManager.default.removeItem(at: consentFile)
            return true
        } catch {
            return DeviceIdStore.isNoSuchFile(error)
        }
    }

    // MARK: - Biçim

    private static func encode(_ c: Consent) -> String {
        "analytics=\(c.analytics)\nattribution=\(c.attribution)\nadSharing=\(c.adSharing)\n"
    }

    /// Katı: her satır `anahtar=true|false`; anahtar bilinen kümeden ve bir kez; üçü de var.
    /// Satır sayısı ayrıca sınanmaz: bilinmeyen/yinelenen anahtar reddi + üçünün varlığı onu zaten ima eder,
    /// böylece her koruma tek başına yük taşır. Başka her şey `nil` (çağıran kapalı okur).
    private static func parse(_ raw: String) -> Consent? {
        guard raw.hasSuffix("\n") else { return nil }
        let lines = raw.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        var seen: [String: Bool] = [:]
        for line in lines {
            let parts = line.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard keys.contains(key), seen[key] == nil else { return nil }
            switch parts[1] {
            case "true": seen[key] = true
            case "false": seen[key] = false
            default: return nil
            }
        }
        guard let a = seen["analytics"], let t = seen["attribution"], let s = seen["adSharing"] else { return nil }
        return Consent(analytics: a, attribution: t, adSharing: s)
    }
}

import Foundation

/// Kalıcı `device_id` deposu: rastgele UUID, yanında IDFV'nin yerel özeti.
///
/// iOS/macOS: `<queueDirectory>/device_id` + `vendor_hash` dosyaları, yedekten hariç.
/// tvOS: `UserDefaults` (`cz_device_id`, `cz_vendor_hash`).
///
/// Bilerek durumsuz bir `struct`: önbellek tutmaz, her çağrı depoyu okur; sahibi (actor Core)
/// çağrıları zaten sıraya koyar.
struct DeviceIdStore: Sendable {
    private let platform: Platform
    /// IDFV özeti, süreç başında ana thread'de bir kez örneklenip buraya değer olarak verilir.
    /// Süreç içinde yeniden okunmaz: kilitli cihazda `nil` geldiyse yedek tespiti o süreç boyunca
    /// atlanır ve sonradan IDFV açılsa da bilerek kaçırılır; güvenli yön budur (kimlik korunur).
    /// Arka plandan ana thread'e senkron sıçrama kilitlenme riski taşıdığı için okuma burada yapılmaz.
    private let vendorHash: String?
    private let uuid: @Sendable () -> String
    private let defaultsSuite: String?
    /// Dosya okumasını enjekte edilebilir kılmanın nedeni: gerçek `isProtectedDataAvailable`
    /// macOS'ta yok, testte de kontrol edilemez. Brief'teki tespit zaten "okuma izin hatasıyla
    /// düşerse koruma kapalı" olduğundan, hatayı veren okuyucuyu değiştirmek gerçek mekanizmanın
    /// kendisini sınar; ayrı bir bayrak uydurulmaz.
    private let readFile: @Sendable (URL) throws -> Data

    static let defaultsIdKey = "cz_device_id"
    static let defaultsHashKey = "cz_vendor_hash"

    init(
        platform: Platform,
        vendorHash: String?,
        uuid: @escaping @Sendable () -> String,
        defaultsSuite: String? = nil,
        readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.platform = platform
        self.vendorHash = vendorHash
        self.uuid = uuid
        self.defaultsSuite = defaultsSuite
        self.readFile = readFile
    }

    private enum Loaded {
        case value(String)
        case absent
        /// Veri koruması kapalı: dosya var olabilir ama okunamıyor.
        case locked
    }

    private var usesDefaults: Bool { platform.name == "tvos" }
    private var idFile: URL { platform.queueDirectory.appendingPathComponent("device_id") }
    private var hashFile: URL { platform.queueDirectory.appendingPathComponent("vendor_hash") }
    private var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Salt okuma: dizin, dosya ya da başka hiçbir iz oluşturmaz ("rızasız kalıcı iz yok").
    func read() -> String? {
        if case .value(let id) = loadId() { return id }
        return nil
    }

    /// Yedek tespiti yapmaz ve doğrulamaz; `getOrCreate()` kullanın.
    func write(_ id: String) {
        _ = persist(id: id)
    }

    /// Kimliği döner; yoksa üretir. Veri koruması kapalıysa `nil` döner ve hiçbir şey yazmaz:
    /// aksi halde her prewarm yeni bir "kullanıcı" yaratırdı.
    func getOrCreate() -> String? {
        let existing: String?
        switch loadId() {
        case .locked: return nil
        case .value(let id): existing = id
        case .absent: existing = nil
        }

        // Kimlik üretimi IDFV'yi beklemez; `nil` ise yalnız hash yazılmaz.
        let current = vendorHash

        guard let id = existing else {
            let fresh = uuid()
            // Yazılamayan kimlik döndürülmez: bir sonraki çağrıda yine "yok" görünür, her seferinde başka id çıkardı.
            guard persist(id: fresh) else { return nil }
            if let current { _ = persist(hash: current) }
            return fresh
        }

        // IDFV yok (yeniden başlatma sonrası kilit hiç açılmadı): kontrol atlanır, kimlik korunur.
        guard let current else { return id }

        switch loadHash() {
        case .locked:
            return nil
        case .absent:
            // Kimlik IDFV yokken üretilmişti ya da eski sürümden geliyor: özeti şimdi bağla.
            _ = persist(hash: current)
            return id
        case .value(let stored):
            if stored == current { return id }
            // IDFV değişti: kimlik yedekten başka cihaza geldi. Aynı id iki cihazda kalmasın.
            // Önce id yazılır; arada kesilirse bir sonraki açılış yine uyuşmazlık görüp yenisini üretir.
            let fresh = uuid()
            guard persist(id: fresh) else { return nil }
            _ = persist(hash: current)
            return fresh
        }
    }

    // MARK: - Depo

    private func loadId() -> Loaded { load(file: idFile, key: Self.defaultsIdKey) }
    private func loadHash() -> Loaded { load(file: hashFile, key: Self.defaultsHashKey) }

    private func load(file: URL, key: String) -> Loaded {
        if usesDefaults {
            guard let s = defaults.string(forKey: key), !s.isEmpty else { return .absent }
            return .value(s)
        }
        do {
            let data = try readFile(file)
            let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? .absent : .value(s)
        } catch {
            return Self.isPermissionDenied(error) ? .locked : .absent
        }
    }

    private func persist(id: String) -> Bool { store(id, file: idFile, key: Self.defaultsIdKey) }
    private func persist(hash: String) -> Bool { store(hash, file: hashFile, key: Self.defaultsHashKey) }

    private func store(_ value: String, file: URL, key: String) -> Bool {
        if usesDefaults {
            defaults.set(value, forKey: key)
            return true
        }
        do {
            // Dizin yalnız gerçek yazımda yaratılır; okuma yolu buraya gelmez.
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: file, options: .atomic)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    /// `NSFileReadNoPermissionError` ya da `EPERM`; Foundation bazen POSIX hatasını alt hata olarak sarar.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EPERM) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }
}

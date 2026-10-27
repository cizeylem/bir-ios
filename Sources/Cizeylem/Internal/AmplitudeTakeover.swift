import Foundation
import SQLite3

struct Takeover: Sendable {
    let deviceId: String
    /// `"configured"`, `"amplitude-swift"` veya `"amplitude-sqlite"`.
    let source: String
    let optOut: Bool
}

/// host uygulamanın bugünkü Amplitude kurulumundan `device_id` devralır; Amplitude ve Çizeylem paralel
/// çalışırken iki raporun cihaz düzeyinde eşleşmesi buna bağlıdır.
///
/// Mutlak kural: SALT OKUMA. Amplitude'un hiçbir kaydı yazılmaz, silinmez, taşınmaz; okuma yolu
/// dizin, dosya ya da UserDefaults anahtarı da yaratmaz.
///
/// Devralınan değer IDFV türevli olabilir (Amplitude-Swift varsayılan olarak IDFV'den türetir) ve bu
/// sorun değil: amaç parity. Bizim KENDİ ürettiğimiz kimlik rastgele UUID olmaya devam eder (SPEC §6).
enum AmplitudeTakeover {
    static let defaultInstance = "$default_instance"

    /// iOS'a özgü sahte/sabit değerler (Amplitude-iOS/Swift kaynağından). Android'in "S ile biten"
    /// kuralı burada YOK; ObjC'nin rastgele id'lere eklediği `R` bir işaretleyicidir, geçersizlik
    /// göstergesi değil, bu yüzden `R`/`S` ekli id'ler geçerlidir.
    private static let invalidIds: Set<String> = [
        "e3f5536a141811db40efd6400f1d0a4e",
        "04bab7ee75b9a58d39b8dc54e8851084",
        "00000000-0000-0000-0000-000000000000",
        "02:00:00:00:00:00",
        "020000000000",
    ]

    /// `apiKey` **Amplitude'un** API anahtarıdır (Çizeylem write key'i değil); `nil`/boş ise
    /// Amplitude-Swift suite'i taranmaz. `String?` alır (çağıranda boş dizgiye düşürmek yerine):
    /// "anahtar yok" durumu tipte görünür kalır ve sahte suite adı hiç kurulmaz.
    ///
    /// Sıra: configured, kendi depomuz, Amplitude-Swift suite'i, eski ObjC SQLite. Kendi depomuzda
    /// kimlik varsa `nil` döner: devralınacak bir şey yok ve `migrated_from` yeniden tetiklenmemeli
    /// (çağıran `getOrCreate()` ile mevcut kimliği okur).
    static func find(apiKey: String?, configured: String?) -> Takeover? {
        find(
            apiKey: apiKey, configured: configured, instance: "",
            ownStore: DeviceIdStore(platform: .current, vendorHash: nil, uuid: { "" }),
            libraryDirectory: defaultLibraryDirectory)
    }

    static func find(
        apiKey: String?, configured: String?, instance: String,
        ownStore: DeviceIdStore, libraryDirectory: URL
    ) -> Takeover? {
        // Açık değer geliştiricinin bilinçli seçimi: yalnız boşluk/boş ise yok sayılır, liste uygulanmaz.
        let explicit = configured.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if explicit == nil, ownStore.read() != nil { return nil }

        // optOut kimlik zincirinden BAĞIMSIZ okunur: kullanıcı eski ObjC SDK'sında çıkış yapıp sonra
        // Swift'e geçmiş olabilir; kimliği hangi kaynak verirse versin bu irade kaybolmamalı.
        // Swift SDK optOut'u kalıcı tutmadığı için tek kaynak ObjC SQLite `long_store`'dur.
        let legacy = LegacyDatabase.read(directory: libraryDirectory, instance: instance)
        let optOut = legacy?.optOut ?? false

        if let explicit {
            return Takeover(deviceId: explicit, source: "configured", optOut: optOut)
        }
        if let id = swiftSuiteDeviceId(apiKey: apiKey, instance: instance), isValid(id) {
            return Takeover(deviceId: id, source: "amplitude-swift", optOut: optOut)
        }
        if let id = legacy?.deviceId, isValid(id) {
            return Takeover(deviceId: id, source: "amplitude-sqlite", optOut: optOut)
        }
        return nil
    }

    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && !invalidIds.contains(id.lowercased())
    }

    /// Boş instance varsayılana normalize olur; küçük harfe ÇEVRİLMEZ (Swift SDK'da böyle).
    /// Ayrı işlev: macOS/APFS dosya adlarında büyük/küçük harf duyarsız olduğundan bu kural
    /// yalnız dosya sistemi üzerinden test edilemez.
    static func swiftSuiteName(apiKey: String, instance: String) -> String {
        let normalized = instance.isEmpty ? defaultInstance : instance
        return "com.amplitude.storage.amplitude-swift-storage-\(apiKey)-\(normalized)"
    }

    /// ObjC: named instance küçük harfe çevrilir; varsayılan örnekte son ek yok.
    static func legacyDatabaseName(instance: String) -> String {
        let normalized = instance.lowercased()
        let isDefault = normalized.isEmpty || normalized == defaultInstance.lowercased()
        return isDefault ? "com.amplitude.database" : "com.amplitude.database_\(normalized)"
    }

    private static func swiftSuiteDeviceId(apiKey: String?, instance: String) -> String? {
        // Anahtar yoksa suite adı kurulamaz: anlamsız bir adla aramak faydasızdır ve niyeti gizler.
        // SQLite yolu anahtara bağlı değil, etkilenmez.
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let name = swiftSuiteName(apiKey: apiKey, instance: instance)
        // `UserDefaults(suiteName:)` yalnız okunur, anahtar yaratmaz. `string(forKey:)` sayıyı da metne
        // çevirir; Amplitude yalnız String yazar, başka tür bozuk veridir.
        return UserDefaults(suiteName: name)?.object(forKey: "device_id") as? String
    }

    /// ObjC SDK tvOS'ta Caches, diğerlerinde Library kullanır.
    private static var defaultLibraryDirectory: URL {
        #if os(tvOS)
        let kind = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let kind = FileManager.SearchPathDirectory.libraryDirectory
        #endif
        // `urls(for:)` dizini yaratmaz.
        return FileManager.default.urls(for: kind, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }
}

/// Eski Amplitude-iOS (ObjC) SQLite deposu, yalnız okunur.
///
/// Yan dosya riski: `SQLITE_OPEN_READONLY` ile açmak veritabanını silmez ve (rollback-journal
/// kipinde) `-wal`/`-shm`/`-journal` yaratmaz; bozuk dosya açılamaz ya da sorgu hata verir ve kaynak
/// atlanır. Testle kilitli: bozuk DB baytları ve dizin listesi değişmez. Android'deki "READONLY
/// bayrağına rağmen bozuk DB silindi" sınıfı hata burada yok, çünkü SQLite böyle bir geri çağrı sunmaz.
private enum LegacyDatabase {
    struct Record { let deviceId: String?; let optOut: Bool }

    static func read(directory: URL, instance: String) -> Record? {
        let path = directory.appendingPathComponent(AmplitudeTakeover.legacyDatabaseName(instance: instance)).path

        // READONLY dosya yaratmaz, yine de yokluğu açıkça bakmak gereksiz hata yolunu önler.
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        // Amplitude aynı süreçte yazıyor olabilir; kısa bekleyip vazgeç.
        sqlite3_busy_timeout(db, 200)

        let deviceId = text(db, "SELECT value FROM store WHERE key = 'device_id'")
        let optOut = integer(db, "SELECT value FROM long_store WHERE key = 'opt_out'") == 1
        return Record(deviceId: deviceId, optOut: optOut)
    }

    private static func text(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { sqlite3_finalize(stmt); return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private static func integer(_ db: OpaquePointer, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { sqlite3_finalize(stmt); return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }
}

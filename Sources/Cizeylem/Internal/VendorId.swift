import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// IDFV'nin yerel özeti. Yalnız yedek tespiti içindir; özet cihazdan çıkmaz ve hiçbir event'e,
/// isteğe ya da loga konmaz.
enum VendorId {
    /// `UIDevice` `@MainActor`'e bağlı: çağıran ana thread'de olmak zorunda (derleyici zorlar,
    /// senkron thread sıçraması yok). `Cizeylem.initialize` bunu bir kez çağırıp değeri
    /// `DeviceIdStore`'a geçirir. IDFV yoksa `nil`: yeniden başlatma sonrası ilk kilit açılana
    /// kadar sistem `nil` döndürebilir.
    @MainActor
    static func currentHash() -> String? {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.identifierForVendor.flatMap { hash(of: $0.uuidString) }
        #else
        // macOS'ta IDFV kavramı yok: yedek tespiti bu platformda devre dışı, kimlik korunur.
        return nil
        #endif
    }

    /// Ham IDFV'yi diske de yazmamak için SHA-256 özeti (küçük harf hex). CryptoKit yoksa `nil`:
    /// ham değeri dönmek "ham IDFV hiçbir yere yazılmaz" kuralını bozardı; `nil` yedek kontrolünü atlatır.
    static func hash(of value: String) -> String? {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

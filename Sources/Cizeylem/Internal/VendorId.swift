import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// IDFV'nin yerel özetini verir. Yalnız yedek tespiti içindir; özet cihazdan çıkmaz ve
/// hiçbir event'e, isteğe ya da loga konmaz.
protocol VendorIdReading: Sendable {
    /// IDFV yoksa `nil`: cihaz yeniden başladıktan sonra ilk kilit açılana kadar sistem `nil` döndürebilir.
    func currentHash() -> String?
}

struct VendorId: VendorIdReading {
    func currentHash() -> String? {
        #if canImport(UIKit) && !os(watchOS)
        // UIDevice @MainActor'a bağlı, protokol ise eşzamanlı ve izolasyonsuz (Core actor'ünden çağrılır).
        // Ana iş parçacığındaysak doğrudan, değilsek ana kuyruğa tek seferlik senkron atlıyoruz;
        // çağıran ana iş parçacığını bekleyen bir yer olmamalı (Core ona `await` ile bağlanır, bloklamaz).
        let idfv: String? = Thread.isMainThread
            ? MainActor.assumeIsolated { UIDevice.current.identifierForVendor?.uuidString }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { UIDevice.current.identifierForVendor?.uuidString } }
        return idfv.map(Self.hash(of:))
        #else
        // macOS'ta IDFV kavramı yok: yedek tespiti bu platformda devre dışı, kimlik korunur.
        return nil
        #endif
    }

    /// Ham IDFV'yi diske de yazmamak için SHA-256 özeti (küçük harf hex).
    static func hash(of value: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return value
        #endif
    }
}

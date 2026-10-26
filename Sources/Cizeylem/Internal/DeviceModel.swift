import Foundation

/// Ham model kodu (`iPhone17,3`, `Mac14,2`). Pazarlama adına çevrilmez: o eşleme sunucuda yapılır,
/// SDK'da tutulursa her yeni cihazda eskir.
enum DeviceModel {
    static var identifier: String { identifier(environment: ProcessInfo.processInfo.environment) }

    static func identifier(environment: [String: String]) -> String {
        // Simülatörde `hw.machine` ana makinenin mimarisini (`arm64`) verir; gerçek model ortamda durur.
        if let sim = environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty {
            return sim
        }
        #if os(macOS)
        // macOS'ta `hw.machine` mimaridir (`arm64`); model kodu `hw.model`'dedir.
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        return sysctlString(key) ?? "unknown"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Sondaki NUL baytı atılır.
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}

import Foundation

/// Uzaktan alınan, sürümlü dönüşüm değeri şeması.
///
/// Geçerlilik **çözme anında** sınanır ve bozuk tek bir kural bütün şemayı götürür: yarım şemayla
/// yazmak, hiç yazmamaktan kötüdür (SKAN postback'i geri alınamaz). Aralık dışı değer kırpılmaz;
/// kırpmak sessizce yanlış bir değer yazdırır.
struct ConversionSchema: Codable, Sendable, Equatable {
    /// Bu SDK'nın anladığı tek sürüm. Daha yeni bir sürüm alanların anlamını değiştirmiş olabilir;
    /// tahminle yazmak yerine reddedilir. Bilinmeyen *alanlar* ise (aynı sürümde) yok sayılır.
    static let supportedVersion = 1
    static let fineRange = 0...63
    static let coarseValues: Set<String> = ["low", "medium", "high"]

    struct Rule: Codable, Sendable, Equatable {
        /// Sayacı tutulan event adı.
        let event: String
        /// Kuralın tetiklenmesi için event'in en az kaç kez görülmüş olması gerektiği (>= 1).
        let min: Int
        let fine: Int
        let coarse: String
        let lockWindow: Bool

        var isValid: Bool {
            !event.isEmpty && min >= 1
                && ConversionSchema.fineRange.contains(fine)
                && ConversionSchema.coarseValues.contains(coarse)
        }
    }

    let version: Int
    let rules: [Rule]

    var isValid: Bool {
        version == Self.supportedVersion && rules.allSatisfy(\.isValid)
    }

    /// Bozuk, eksik, sürümsüz ya da aralık dışı her şey `nil`: çağıran hiçbir şey yazmaz.
    static func decode(_ data: Data) -> ConversionSchema? {
        // `version` Optional değildir: yoksa çözme patlar (varsayılan sürüm yok).
        guard let schema = try? JSONDecoder().decode(ConversionSchema.self, from: data),
              schema.isValid else { return nil }
        return schema
    }
}

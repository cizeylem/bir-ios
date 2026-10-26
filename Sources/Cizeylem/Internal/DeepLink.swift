import Foundation

/// Deep link sorgu parametrelerinden **yalnız beyaz listedekiler** okunur (SPEC §3).
///
/// Beyaz liste dışı hiçbir anahtar — ve tam URL'in kendisi de — event'e konmaz: derin
/// bağlantılar e-posta, oturum belirteci, sipariş numarası gibi serbest metin taşır ve
/// bunları analitiğe yazmak sessiz bir veri sızıntısıdır. Bu yüzden liste "neyi atalım"
/// değil, "neyi alalım" biçimindedir.
enum DeepLink {
    /// `utm_` ile başlayan her anahtar artı bu ikisi. `click_id` genel tıklama kimliği,
    /// `campaign_ids` Meta'nın (deferred) deep link alanı.
    private static let exact: Set<String> = ["click_id", "campaign_ids"]
    private static let prefix = "utm_"

    static func allows(_ key: String) -> Bool {
        // Büyük/küçük harfe DUYARLI: `UTM_SOURCE` bizim beklediğimiz anahtar değil ve
        // "yakın görüneni" kabul etmek beyaz listeyi fiilen genişletirdi.
        key.hasPrefix(prefix) || exact.contains(key)
    }

    /// Sorgu dizesindeki beyaz liste anahtarları. Sorgu yoksa, ayrıştırılamıyorsa ya da
    /// hiçbiri eşleşmiyorsa boş sözlük.
    ///
    /// Yüzde kodlaması `URLComponents` tarafından çözülür. Değeri olmayan anahtar
    /// (`?utm_source`) yazılmaz: "boş değer" ile "değer yok" farklı şeylerdir ve sunucuya
    /// uydurulmuş bir boş string göndermeyiz. Yinelenen anahtarda **ilk** değer kazanır
    /// (sonrakiyle ezmek, sorgu dizesine sonradan eklenen bir anahtarın ilkini ezmesine
    /// izin verirdi).
    static func params(_ url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            guard allows(item.name), let value = item.value, out[item.name] == nil else { continue }
            out[item.name] = value
        }
        return out
    }
}

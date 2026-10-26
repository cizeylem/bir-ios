import Foundation

/// Tek bir isteğin sonucu (PROTOCOL §5). Çağıran bunu davranışa çevirir.
enum Outcome: Sendable {
    /// Kabul edildi: batch kuyruktan silinir.
    case ok
    /// Sunucu gövdeyi kalıcı olarak reddetti (400): batch atılır, tekrar denenmez.
    case drop
    /// 413: batch bölünüp tekrar denenir.
    case split
    /// Geçici ya da bilinmeyen: hiçbir şey silinmez, backoff ile aynı `insert_id`'lerle tekrar.
    case retry
    /// 401/403: yapılandırma hatası, SDK durur.
    case fatal
}

/// Tek bir `POST {endpoint}/v1/batch` yapar ve sonucu eşler. Tekrar saymaz, üst sınır koymaz;
/// backoff ve tekrar çağıranın işidir.
///
/// Eşleme `bir-js`'teki `send` ile birebir. Özel olan yalnız `2xx`, `400`, `401`/`403`, `413`;
/// geri kalan HER şey (404, 408, 422, 3xx, 5xx, ağ hatası) `retry`: bilinmeyen bir kodu `drop`
/// saymak veriyi sessizce kaybettirir, `retry` saymanın bedeli ise yalnız bir sonraki denemedir.
struct Transport: Sendable {
    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let compress: @Sendable (Data) -> Data?

    init(
        endpoint: URL,
        apiKey: String,
        session: URLSession,
        now: @escaping @Sendable () -> Date = { Date() },
        compress: @escaping @Sendable (Data) -> Data? = Gzip.compress
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.session = session
        self.now = now
        self.compress = compress
    }

    /// `retryAfter` saniyedir ve yalnız `retry` dönen yanıtlarda dolar (referans, başlığı yalnız
    /// düşüş yolunda okur; `drop`/`fatal`/`split` kararını başlık değiştirmemeli).
    func send(body: String) async -> (Outcome, retryAfter: Double?) {
        let raw = Data(body.utf8)
        var request = URLRequest(url: batchURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sıkıştırma tutmazsa gövde düz gider: başlık gövdeyle tutarlı olmalı, yoksa sunucu çözemez.
        if let gz = compress(raw) {
            request.httpBody = gz
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            request.httpBody = raw
        }

        let response: URLResponse
        do {
            // Gövde hiç okunmaz: yanıt kodu yeter, sınırsız bir hata gövdesi belleğe girmesin.
            // `bytes` dizisi tüketilmeden bırakılınca görev iptal olur.
            let (_, r) = try await session.bytes(for: request, delegate: NoRedirect())
            response = r
        } catch {
            return (.retry, nil)
        }
        guard let http = response as? HTTPURLResponse else { return (.retry, nil) }

        switch http.statusCode {
        case 200...299: return (.ok, nil)
        case 400: return (.drop, nil)
        case 401, 403: return (.fatal, nil)
        case 413: return (.split, nil)
        default: return (.retry, retryAfter(http))
        }
    }

    private func batchURL() -> URL {
        // `endpoint` sonunda `/` varsa `//v1/batch` oluşmasın.
        var s = endpoint.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/v1/batch") ?? endpoint.appendingPathComponent("v1/batch")
    }

    /// Saniye sayısı ya da HTTP-date; geçmiş tarih ve negatif sayı 0'a kırpılır. Anlaşılmayan
    /// değer `nil`: çağıran kendi takvimine döner.
    private func retryAfter(_ http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = Double(raw) {
            // NaN/Infinity geçerli Double'dır ama bekleme süresi olamaz.
            return secs.isFinite ? max(0, secs) : nil
        }
        guard let when = Transport.httpDate(raw) else { return nil }
        return max(0, when.timeIntervalSince(now()))
    }

    /// RFC 9110'un üç tarih biçimi (IMF-fixdate, RFC 850, asctime).
    private static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// Yönlendirmeyi izlemez: bir 3xx, Authorization başlığıyla gövdeyi sessizce başka bir uca
/// POST'lamasın. 3xx zaten `retry` sayılır.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

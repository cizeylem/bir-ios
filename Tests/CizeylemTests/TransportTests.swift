import XCTest
@testable import Cizeylem

/// Sahte ağ. Yanıt, oturumun `X-Stub` başlığında taşınır (durumsuz); gelen istekler actor'a
/// kaydedilir. Kayıt ve yanıt arasındaki yarış, `startLoading`'in kaydı bekleyip sonra teslim
/// etmesiyle kapanır: `send` döndüğünde kayıt kesinlikle tamamdır, yani testler yalancı yeşile
/// düşemez. `startLoading` URLSession'ın kendi iş parçacığında koşar (eşzamanlılık havuzunda
/// değil), Task ise havuzda; semafor beklemesi bu yüzden kilitlenmez.
enum Stub: Sendable, Codable {
    case status(Int, headers: [String: String])
    case failure(Int)
    case redirect(Int, to: String)

    var header: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }
    static func decode(_ h: String?) -> Stub {
        guard let h, let d = Data(base64Encoded: h),
              let s = try? JSONDecoder().decode(Stub.self, from: d) else { return .status(200, headers: [:]) }
        return s
    }
}

struct Seen: Sendable {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let timeout: TimeInterval
    let body: Data
}

actor Registry {
    static let shared = Registry()
    private var seen: [Seen] = []
    func reset() { seen = [] }
    func record(_ s: Seen) { seen.append(s) }
    func requests() -> [Seen] { seen }
}

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(contentsOf: buf[0..<n])
            }
            s.close()
        } else if let b = request.httpBody { body = b }
        let url = request.url!
        let seen = Seen(
            url: url, method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            timeout: request.timeoutInterval, body: body)
        let done = DispatchSemaphore(value: 0)
        Task {
            await Registry.shared.record(seen)
            done.signal()
        }
        // Süreli bekleme: `startLoading` bugün URLSession'ın kendi iş parçacığında koşuyor, ama ileride
        // eşzamanlılık havuzuna taşınırsa süresiz bekleme CI'yı sessizce ASARDI. Zaman aşımı bunu
        // gürültülü bir başarısızlığa çevirir; asılı bir koşu hata veren bir koşudan çok daha kötüdür.
        if done.wait(timeout: .now() + 10) == .timedOut {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        switch Stub.decode(seen.headers["X-Stub"]) {
        case .status(let code, let headers):
            let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"gövde\":\"x\"}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
        case .redirect(let code, let to):
            let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                    headerFields: ["Location": to])!
            var next = request
            next.url = URL(string: to)
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: r)
            // Temsilci yönlendirmeyi reddederse 3xx yanıtı olduğu gibi teslim edilir.
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class TransportTests: XCTestCase {
    private let endpoint = URL(string: "https://ingest.example.com")!
    // 2025-01-01T00:00:00Z
    private let now = Date(timeIntervalSince1970: 1_735_689_600)

    private func session(_ stub: Stub) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        cfg.httpAdditionalHeaders = ["X-Stub": stub.header]
        return URLSession(configuration: cfg)
    }

    private func transport(_ stub: Stub = .status(200, headers: [:]), apiKey: String = "ck_test") -> Transport {
        Transport(endpoint: endpoint, apiKey: apiKey, session: session(stub), now: { [now] in now })
    }

    private func send(_ stub: Stub, body: String = "{\"events\":[]}") async -> (Outcome, retryAfter: Double?) {
        await Registry.shared.reset()
        return await transport(stub).send(body: body)
    }

    private func st(_ code: Int, _ h: [String: String] = [:]) -> Stub { .status(code, headers: h) }

    func test200OkDondurur() async {
        let r = await send(st(200))
        XCTAssertEqual(r.0, .ok)
        XCTAssertNil(r.retryAfter)
    }

    func testTum2xxOk() async {
        for c in [200, 201, 202, 204, 299] {
            let r = await send(st(c))
            XCTAssertEqual(r.0, .ok, "\(c)")
        }
    }

    func test400DropDondurur() async {
        let r = await send(st(400))
        XCTAssertEqual(r.0, .drop)
    }

    func test401Ve403FatalDondurur() async {
        let a = await send(st(401)); XCTAssertEqual(a.0, .fatal)
        let b = await send(st(403)); XCTAssertEqual(b.0, .fatal)
    }

    func test413SplitDondurur() async {
        let r = await send(st(413))
        XCTAssertEqual(r.0, .split)
    }

    func test429RetryVeRetryAfterSaniyesi() async {
        let r = await send(st(429, ["Retry-After": "7"]))
        XCTAssertEqual(r.0, .retry)
        XCTAssertEqual(r.retryAfter, 7)
    }

    func testRetryAfterOndalikSaniye() async {
        let r = await send(st(429, ["Retry-After": "1.5"]))
        XCTAssertEqual(r.retryAfter, 1.5)
    }

    func testRetryAfterHTTPDateBicimiCevrilir() async {
        // now + 90 sn
        let r = await send(st(429, ["Retry-After": "Wed, 01 Jan 2025 00:01:30 GMT"]))
        XCTAssertEqual(r.0, .retry)
        XCTAssertEqual(r.retryAfter, 90)
    }

    func testRetryAfterRFC850VeAsctimeBicimleri() async {
        let a = await send(st(503, ["Retry-After": "Wednesday, 01-Jan-25 00:01:30 GMT"]))
        XCTAssertEqual(a.retryAfter, 90)
        let b = await send(st(503, ["Retry-After": "Wed Jan  1 00:01:30 2025"]))
        XCTAssertEqual(b.retryAfter, 90)
    }

    func testRetryAfterGecmisHTTPDate0aKirpilir() async {
        let r = await send(st(429, ["Retry-After": "Tue, 31 Dec 2024 23:00:00 GMT"]))
        XCTAssertEqual(r.retryAfter, 0)
    }

    func testRetryAfterNegatifSaniye0aKirpilir() async {
        let r = await send(st(429, ["Retry-After": "-5"]))
        XCTAssertEqual(r.retryAfter, 0)
    }

    func testRetryAfterCopHeaderNilDoner() async {
        let r = await send(st(429, ["Retry-After": "yarın bakarız"]))
        XCTAssertEqual(r.0, .retry)
        XCTAssertNil(r.retryAfter)
        let r2 = await send(st(429, ["Retry-After": "nan"]))
        XCTAssertNil(r2.retryAfter, "NaN sonsuz bekleme/çökme olmasın")
        let r3 = await send(st(429, ["Retry-After": "inf"]))
        XCTAssertNil(r3.retryAfter)
    }

    func testRetryAfterYoksaNil() async {
        let r = await send(st(429))
        XCTAssertEqual(r.0, .retry)
        XCTAssertNil(r.retryAfter)
    }

    func testRetryAfterBoslukluSaniyeKabulEdilir() async {
        let r = await send(st(503, ["Retry-After": " 12 "]))
        XCTAssertEqual(r.retryAfter, 12)
    }

    func testRetryAfter503teDeOkunur() async {
        let r = await send(st(503, ["Retry-After": "30"]))
        XCTAssertEqual(r.0, .retry)
        XCTAssertEqual(r.retryAfter, 30)
    }

    func testRetryAfter400deYokSayilirDropKazanir() async {
        let r = await send(st(400, ["Retry-After": "30"]))
        XCTAssertEqual(r.0, .drop)
        XCTAssertNil(r.retryAfter)
    }

    func testRetryAfter401ve413teDeNil() async {
        let a = await send(st(401, ["Retry-After": "30"])); XCTAssertNil(a.retryAfter)
        let b = await send(st(413, ["Retry-After": "30"])); XCTAssertNil(b.retryAfter)
        let c = await send(st(200, ["Retry-After": "30"])); XCTAssertNil(c.retryAfter)
    }

    func test5xxVeAgHatasiRetryDondurur() async {
        for c in [500, 502, 503, 504, 599] {
            let r = await send(st(c))
            XCTAssertEqual(r.0, .retry, "\(c)")
        }
        let n = await send(.failure(URLError.notConnectedToInternet.rawValue))
        XCTAssertEqual(n.0, .retry)
        XCTAssertNil(n.retryAfter)
        let t = await send(.failure(URLError.timedOut.rawValue))
        XCTAssertEqual(t.0, .retry)
    }

    func testEslenmemisKodlarRetryDonerVeriKaybolmaz() async {
        for c in [404, 408, 409, 410, 418, 422, 451, 302, 301, 307, 100, 199] {
            let r = await send(st(c))
            XCTAssertEqual(r.0, .retry, "\(c) eşlenmemiş: retry olmalı, drop değil")
        }
    }

    func testSinirKodlari() async {
        let a = await send(st(399)); XCTAssertEqual(a.0, .retry)
        let b = await send(st(402)); XCTAssertEqual(b.0, .retry)
        let c = await send(st(404)); XCTAssertEqual(c.0, .retry)
        let d = await send(st(414)); XCTAssertEqual(d.0, .retry)
        let e = await send(st(300)); XCTAssertEqual(e.0, .retry)
    }

    func test302YonlendirmeIzlenmezVeRetryDoner() async {
        let r = await send(.redirect(302, to: "https://evil.example.net/v1/batch"))
        XCTAssertEqual(r.0, .retry)
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.count, 1, "yönlendirme hedefine ikinci bir POST atılmamalı")
        XCTAssertEqual(seen.first?.url?.host, "ingest.example.com")
    }

    func test307YonlendirmeIzlenmez() async {
        let r = await send(.redirect(307, to: "https://evil.example.net/x"))
        XCTAssertEqual(r.0, .retry)
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.count, 1)
    }

    func testAuthorizationBasligiBearerApiKey() async {
        await Registry.shared.reset()
        _ = await transport(apiKey: "ck_abc123").send(body: "{}")
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.headers["Authorization"], "Bearer ck_abc123")
    }

    func testContentEncodingGzipBasligiYazilir() async {
        let r = await send(st(200))
        XCTAssertEqual(r.0, .ok)
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.headers["Content-Encoding"], "gzip")
        XCTAssertEqual(seen.first?.headers["Content-Type"], "application/json")
    }

    func testPOSTVeUrlSonuBatch() async {
        _ = await send(st(200))
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.method, "POST")
        XCTAssertEqual(seen.first?.url?.absoluteString, "https://ingest.example.com/v1/batch")
    }

    func testEndpointSonundakiEgikCizgiCiftlenmez() async {
        await Registry.shared.reset()
        let t = Transport(endpoint: URL(string: "https://ingest.example.com/")!, apiKey: "k",
                          session: session(st(200)))
        _ = await t.send(body: "{}")
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.url?.absoluteString, "https://ingest.example.com/v1/batch")
    }

    func testIstekZamanAsimi30Saniye() async {
        _ = await send(st(200))
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.timeout, 30)
    }


    func testGovdeGzipZarfiIcindeGonderilir() async {
        let json = "{\"events\":[{\"event\":\"ö\"}]}"
        _ = await send(st(200), body: json)
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.body, Gzip.compress(Data(json.utf8)))
        XCTAssertEqual(Array((seen.first?.body ?? Data()).prefix(3)), [0x1f, 0x8b, 0x08])
    }

    func testSikistirmaBasarisizsaGovdeDuzGiderVeBaslikYazilmaz() async {
        await Registry.shared.reset()
        let t = Transport(endpoint: endpoint, apiKey: "k", session: session(st(200)),
                          compress: { _ in nil })
        let r = await t.send(body: "{\"a\":1}")
        XCTAssertEqual(r.0, .ok)
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.first?.body, Data("{\"a\":1}".utf8))
        XCTAssertNil(seen.first?.headers["Content-Encoding"], "düz gövdeye gzip başlığı yazılırsa sunucu çözemez")
    }

    func testBirIstekBirDenemeTekrarSaymaz() async {
        _ = await send(st(503))
        let seen = await Registry.shared.requests()
        XCTAssertEqual(seen.count, 1)
    }
}

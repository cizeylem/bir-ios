import XCTest
@testable import Cizeylem

final class DeepLinkTests: XCTestCase {
    private func params(_ s: String) -> [String: String] {
        guard let url = URL(string: s) else { return ["__GECERSIZ_URL__": s] }
        return DeepLink.params(url)
    }

    // MARK: - Beyaz liste

    func testUtmParametreleriAlinir() {
        let p = params("https://example.com/x?utm_source=meta&utm_medium=cpc&utm_campaign=yaz&utm_term=t&utm_content=c")
        XCTAssertEqual(p, [
            "utm_source": "meta", "utm_medium": "cpc", "utm_campaign": "yaz",
            "utm_term": "t", "utm_content": "c",
        ])
    }

    func testBilinmeyenUtmOnekliAnahtarDaAlinir() {
        // Beyaz liste "utm_ ile başlayan HER anahtar"; sabit bir beşli değil.
        let p = params("https://example.com/x?utm_yeni_alan=1")
        XCTAssertEqual(p, ["utm_yeni_alan": "1"])
    }

    func testClickIdVeCampaignIdsAlinir() {
        let p = params("example://ac?click_id=abc123&campaign_ids=11,22")
        XCTAssertEqual(p, ["click_id": "abc123", "campaign_ids": "11,22"])
    }

    func testBeyazListeDisiParametrelerAtilir() {
        let p = params("https://example.com/x?utm_source=meta&email=a%40b.com&token=gizli&fbclid=zzz&gclid=yyy")
        XCTAssertEqual(p, ["utm_source": "meta"], "beyaz liste dışı hiçbir anahtar okunmaz")
    }

    func testUtmOnekiBuyukHarfliyseAlinmaz() {
        // Anahtar karşılaştırması büyük/küçük harfe DUYARLI: `UTM_SOURCE` bizim beklediğimiz
        // anahtar değil ve "yakın görünen" bir anahtarı kabul etmek beyaz listeyi delerdi.
        let p = params("https://example.com/x?UTM_SOURCE=meta&Click_Id=1")
        XCTAssertEqual(p, [:])
    }

    func testUtmOnekininKendisiAnahtarsaAlinir() {
        let p = params("https://example.com/x?utm_=bos")
        XCTAssertEqual(p, ["utm_": "bos"])
    }

    func testOnekIcerenAmaBaslamayanAnahtarAlinmaz() {
        let p = params("https://example.com/x?x_utm_source=meta&xclick_id=1")
        XCTAssertEqual(p, [:], "önek yalnız BAŞTA aranır")
    }

    // MARK: - Biçim

    func testYuzdeKodlamasiCozulur() {
        let p = params("https://example.com/x?utm_campaign=yaz%20indirimi%26")
        XCTAssertEqual(p, ["utm_campaign": "yaz indirimi&"])
    }

    func testDegersizParametreAtilir() {
        // `?utm_source` (= yok) `value == nil` verir; boş string ile karıştırılmaz.
        let p = params("https://example.com/x?utm_source&utm_medium=")
        XCTAssertEqual(p, ["utm_medium": ""], "değeri olmayan anahtar yazılmaz, boş değer yazılır")
    }

    func testYinelenenAnahtardaIlkDegerKazanir() {
        let p = params("https://example.com/x?utm_source=a&utm_source=b")
        XCTAssertEqual(p, ["utm_source": "a"])
    }

    func testBozukURLBosSozlukDondurur() {
        XCTAssertEqual(params("https://example.com/x"), [:], "sorgu yok")
        XCTAssertEqual(params("example://"), [:])
        XCTAssertEqual(params("https://example.com/x#utm_source=meta"), [:], "fragment sorgu değildir")
        XCTAssertEqual(params("mailto:a@b.com"), [:])
    }

    func testSorguFragmentIcindeyseAlinmaz() {
        let p = params("https://example.com/x?utm_source=meta#utm_medium=cpc")
        XCTAssertEqual(p, ["utm_source": "meta"])
    }
}

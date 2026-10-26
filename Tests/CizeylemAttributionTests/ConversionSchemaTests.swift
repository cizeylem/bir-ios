import XCTest
@testable import CizeylemAttribution

final class ConversionSchemaTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func schemaJSON(version: String = "\"version\": 1", rule: String) -> Data {
        data("{\(version), \"rules\": [\(rule)]}")
    }

    private func rule(event: String = "purchase", min: Int = 1, fine: Int = 10,
                      coarse: String = "high", lock: Bool = false) -> String {
        "{\"event\": \"\(event)\", \"min\": \(min), \"fine\": \(fine), \"coarse\": \"\(coarse)\", \"lockWindow\": \(lock)}"
    }

    func testSemaJSONdanCozulur() throws {
        let json = data("""
        {"version": 1, "rules": [
          {"event": "first_open", "min": 1, "fine": 3, "coarse": "low", "lockWindow": false},
          {"event": "purchase", "min": 2, "fine": 40, "coarse": "high", "lockWindow": true}
        ]}
        """)
        let schema = try XCTUnwrap(ConversionSchema.decode(json))
        XCTAssertEqual(schema.version, 1)
        XCTAssertEqual(schema.rules.count, 2)
        XCTAssertEqual(schema.rules[1].event, "purchase")
        XCTAssertEqual(schema.rules[1].min, 2)
        XCTAssertEqual(schema.rules[1].fine, 40)
        XCTAssertEqual(schema.rules[1].coarse, "high")
        XCTAssertTrue(schema.rules[1].lockWindow)
    }

    func testBilinmeyenAlanlarSemayiBozmaz() throws {
        let json = data("""
        {"version": 1, "yeni_ust_alan": {"x": 1}, "rules": [
          {"event": "purchase", "min": 1, "fine": 10, "coarse": "medium", "lockWindow": false, "gelecek": [1,2]}
        ]}
        """)
        let schema = try XCTUnwrap(ConversionSchema.decode(json))
        XCTAssertEqual(schema.rules.first?.fine, 10)
    }

    func testSurumAlaniZorunlu() {
        XCTAssertNil(ConversionSchema.decode(schemaJSON(version: "\"x\": 1", rule: rule())))
        XCTAssertNotNil(ConversionSchema.decode(schemaJSON(rule: rule())))
    }

    func testSurumTipiYanlisYaDaDestekDisiysaReddedilir() {
        XCTAssertNil(ConversionSchema.decode(schemaJSON(version: "\"version\": \"1\"", rule: rule())))
        XCTAssertNil(ConversionSchema.decode(schemaJSON(version: "\"version\": 0", rule: rule())))
        // Bilinmeyen yeni sürüm anlamı değişmiş olabilir: tahminle yazmaktansa yazmamak.
        XCTAssertNil(ConversionSchema.decode(schemaJSON(version: "\"version\": 2", rule: rule())))
    }

    func testFineAraligiDisiReddedilirKirpilmaz() {
        XCTAssertNil(ConversionSchema.decode(schemaJSON(rule: rule(fine: 64))))
        XCTAssertNil(ConversionSchema.decode(schemaJSON(rule: rule(fine: -1))))
        XCTAssertNil(ConversionSchema.decode(schemaJSON(rule: rule(fine: 1000))))
        XCTAssertEqual(ConversionSchema.decode(schemaJSON(rule: rule(fine: 0)))?.rules.first?.fine, 0)
        XCTAssertEqual(ConversionSchema.decode(schemaJSON(rule: rule(fine: 63)))?.rules.first?.fine, 63)
    }

    func testCoarseYalnizLowMediumHigh() {
        for ok in ["low", "medium", "high"] {
            XCTAssertNotNil(ConversionSchema.decode(schemaJSON(rule: rule(coarse: ok))), ok)
        }
        for bad in ["", "HIGH", "very_high", "none", " low"] {
            XCTAssertNil(ConversionSchema.decode(schemaJSON(rule: rule(coarse: bad))), bad)
        }
    }

    func testBozukKuralTumSemayiReddeder() {
        // Biri geçerli biri bozuk: yarım şema uygulanmaz.
        let json = data("{\"version\": 1, \"rules\": [\(rule()), \(rule(fine: 99))]}")
        XCTAssertNil(ConversionSchema.decode(json))
    }

    func testEksikAlanlarVeBozukJSONReddedilir() {
        XCTAssertNil(ConversionSchema.decode(data("")))
        XCTAssertNil(ConversionSchema.decode(data("{not json")))
        XCTAssertNil(ConversionSchema.decode(data("{\"version\": 1}")))
        XCTAssertNil(ConversionSchema.decode(data("{\"version\": 1, \"rules\": [{\"event\": \"a\", \"fine\": 1}]}")))
        XCTAssertNil(ConversionSchema.decode(schemaJSON(rule: rule(event: ""))))
        XCTAssertNil(ConversionSchema.decode(schemaJSON(rule: rule(min: 0))))
    }
}

import XCTest
@testable import Orvia

final class TextTransformerTests: XCTestCase {
    func testPrettyJSON() {
        let result = TextTransformer.apply(.prettyJSON, to: "{\"b\":1,\"a\":2}")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("\n") == true)
    }

    func testPrettyJSONInvalid() {
        XCTAssertNil(TextTransformer.apply(.prettyJSON, to: "not json"))
    }

    func testBase64RoundTrip() {
        let encoded = TextTransformer.apply(.base64Encode, to: "orvia")
        XCTAssertEqual(encoded, "b3J2aWE=")
        XCTAssertEqual(TextTransformer.apply(.base64Decode, to: encoded!), "orvia")
    }

    func testCaseTransforms() {
        XCTAssertEqual(TextTransformer.apply(.camelCase, to: "user_first_name"), "userFirstName")
        XCTAssertEqual(TextTransformer.apply(.snakeCase, to: "userFirstName"), "user_first_name")
        XCTAssertEqual(TextTransformer.apply(.upperCase, to: "abc"), "ABC")
        XCTAssertEqual(TextTransformer.apply(.trimWhitespace, to: "  x \n"), "x")
    }
}

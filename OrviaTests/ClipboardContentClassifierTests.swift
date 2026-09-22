import XCTest
@testable import Orvia

final class ClipboardContentClassifierTests: XCTestCase {
    func testURLClassification() {
        XCTAssertEqual(ClipboardContentClassifier.classifyText("https://openai.com"), .url)
    }

    func testEmailClassification() {
        XCTAssertEqual(ClipboardContentClassifier.classifyText("dev@example.com"), .email)
    }

    func testCodeClassification() {
        let source = "import Foundation\nstruct User { let id: Int }"
        XCTAssertEqual(ClipboardContentClassifier.classifyText(source), .code)
    }

    func testLongTextClassification() {
        let longText = String(repeating: "a", count: 600)
        XCTAssertEqual(ClipboardContentClassifier.classifyText(longText), .longText)
    }

    func testSHAProducesStableHash() {
        let first = ClipboardContentClassifier.sha256Hex(Data("hello".utf8))
        let second = ClipboardContentClassifier.sha256Hex(Data("hello".utf8))
        XCTAssertEqual(first, second)
    }
}

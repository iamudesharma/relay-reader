import XCTest
@testable import SupertonicCore

final class TextBudgetTests: XCTestCase {
  func testLongUnbrokenTextKeepsItsEndingWithoutExceedingWindow() {
    let text = String(repeating: "abcdefghij", count: 30)
    let chunks = Supertonic3TextChunker.chunk(text: text, maxLen: 70)
    XCTAssertEqual(chunks.joined(), text)
    XCTAssertTrue(chunks.allSatisfy { $0.unicodeScalars.count <= 70 })
  }

  func testDecomposedKoreanStaysWithinEncoderBudgetAndPreservesText() {
    let text = String(repeating: "안녕하세요", count: 25)
    let chunks = Supertonic3TextChunker.chunk(text: text, maxLen: 57)
    XCTAssertEqual(chunks.joined(), text)
    XCTAssertTrue(chunks.allSatisfy { $0.decomposedStringWithCompatibilityMapping.unicodeScalars.count <= 57 })
  }

  func testAccentHeavyWordsKeepTheirContent() {
    let text = String(repeating: "é", count: 100)
    let chunks = Supertonic3TextChunker.chunk(text: text, maxLen: 70)
    XCTAssertEqual(chunks.joined(), text)
    XCTAssertTrue(chunks.allSatisfy { $0.decomposedStringWithCompatibilityMapping.unicodeScalars.count <= 70 })
  }
}

import XCTest

final class DuplicateDetectionTests: XCTestCase {
    // No tests yet

    func testSHA256HashOfHelloWorld() {
        let data = Data("hello world".utf8)
        let expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        let actual = ImageSignature.sha256(data)
        XCTAssertEqual(actual, expected)
    }
} 
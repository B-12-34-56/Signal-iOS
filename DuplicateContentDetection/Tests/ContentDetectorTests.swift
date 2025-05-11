import XCTest
@testable import DuplicateContentDetection

class ContentDetectorTests: XCTestCase {
    var contentDetector: ContentDetector!
    
    override func setUp() {
        super.setUp()
        contentDetector = ContentDetector()
    }
    
    func testProcessFile() async throws {
        // Create a temporary file
        let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "Test content".write(to: tempFileURL, atomically: true, encoding: .utf8)
        
        // Process the file
        try await contentDetector.processFile(at: tempFileURL)
        
        // Clean up
        try FileManager.default.removeItem(at: tempFileURL)
    }
} 
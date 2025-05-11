import XCTest
@testable import DuplicateContentDetection

class ContentDetectorTests: XCTestCase {
    var contentDetector: ContentDetector!
    var tempImageURL: URL!
    
    override func setUp() {
        super.setUp()
        contentDetector = ContentDetector()
        
        // Create a temporary test image
        let tempDir = FileManager.default.temporaryDirectory
        tempImageURL = tempDir.appendingPathComponent("test_image.jpg")
        
        // Create a simple red image
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        
        // Save the image
        if let imageData = image.jpegData(compressionQuality: 1.0) {
            try? imageData.write(to: tempImageURL)
        }
    }
    
    override func tearDown() {
        // Clean up the temporary image
        try? FileManager.default.removeItem(at: tempImageURL)
        super.tearDown()
    }
    
    func testDuplicateDetection() {
        // First attempt should succeed (not a duplicate)
        let firstResult = contentDetector.processImage(at: tempImageURL)
        XCTAssertTrue(firstResult, "First image should be processed successfully")
        
        // Second attempt should fail (duplicate)
        let secondResult = contentDetector.processImage(at: tempImageURL)
        XCTAssertFalse(secondResult, "Second image should be detected as duplicate")
    }
} 
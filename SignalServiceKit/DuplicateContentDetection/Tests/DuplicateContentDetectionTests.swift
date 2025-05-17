import XCTest
@testable import DuplicateContentDetection
import AWSCore
import AWSS3
import AWSDynamoDB
import AWSCognitoIdentityProvider

class DuplicateContentDetectionTests: XCTestCase {
    var awsManager: AWSManager!
    var testImageData: Data!
    
    override func setUp() async throws {
        try await super.setUp()
        awsManager = AWSManager.shared
        
        // Create test image data
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        testImageData = image.pngData()!
        
        // Initialize AWS SDK with test credentials
        awsManager.updateCredentials(
            accessKey: "YOUR_ACCESS_KEY",
            secretKey: "YOUR_SECRET_KEY",
            sessionToken: "YOUR_SESSION_TOKEN"
        )
    }
    
    override func tearDown() async throws {
        awsManager = nil
        testImageData = nil
        try await super.tearDown()
    }
    
    func testCheckForDuplicate() async throws {
        // First check should return false (not a duplicate)
        let isDuplicate1 = try await awsManager.checkForDuplicate(imageData: testImageData)
        XCTAssertFalse(isDuplicate1, "First check should not find a duplicate")
        
        // Store the image signature
        try await awsManager.storeImageSignature(imageData: testImageData)
        
        // Second check should return true (is a duplicate)
        let isDuplicate2 = try await awsManager.checkForDuplicate(imageData: testImageData)
        XCTAssertTrue(isDuplicate2, "Second check should find a duplicate")
    }
    
    func testStoreImageSignature() async throws {
        // Store the image signature
        try await awsManager.storeImageSignature(imageData: testImageData)
        
        // Check that it was stored correctly
        let isDuplicate = try await awsManager.checkForDuplicate(imageData: testImageData)
        XCTAssertTrue(isDuplicate, "Image signature should be found after storing")
    }
    
    func testDifferentImagesNotDetectedAsDuplicates() async throws {
        // Store first image
        try await awsManager.storeImageSignature(imageData: testImageData)
        
        // Create different test image data
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let differentImage = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let differentImageData = differentImage.pngData()!
        
        // Check that different image is not detected as duplicate
        let isDuplicate = try await awsManager.checkForDuplicate(imageData: differentImageData)
        XCTAssertFalse(isDuplicate, "Different image should not be detected as duplicate")
    }
    
    func testTemporaryCredentials() async throws {
        // Update with temporary credentials
        awsManager.updateCredentials(
            accessKey: "TEMP_ACCESS_KEY",
            secretKey: "TEMP_SECRET_KEY",
            sessionToken: "TEMP_SESSION_TOKEN"
        )
        
        // Test that operations still work with temporary credentials
        let isDuplicate1 = try await awsManager.checkForDuplicate(imageData: testImageData)
        XCTAssertFalse(isDuplicate1, "First check should not find a duplicate")
        
        try await awsManager.storeImageSignature(imageData: testImageData)
        
        let isDuplicate2 = try await awsManager.checkForDuplicate(imageData: testImageData)
        XCTAssertTrue(isDuplicate2, "Second check should find a duplicate")
    }
} 
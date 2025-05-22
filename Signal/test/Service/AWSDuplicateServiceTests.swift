import XCTest
@testable import Signal

class AWSDuplicateServiceTests: XCTestCase {
    let duplicateService = AWSDuplicateService.shared
    
    func testDuplicateDetection() {
        // Create a test image
        let testImage = UIImage(named: "test_image") ?? UIImage()
        
        // First upload should succeed
        let expectation1 = expectation(description: "First upload should succeed")
        duplicateService.checkAndUploadImage(testImage) { result in
            switch result {
            case .success:
                expectation1.fulfill()
            case .failure(let error):
                XCTFail("First upload failed: \(error)")
            }
        }
        
        // Second upload of same image should fail with duplicate error
        let expectation2 = expectation(description: "Second upload should detect duplicate")
        duplicateService.checkAndUploadImage(testImage) { result in
            switch result {
            case .success:
                XCTFail("Duplicate image was not detected")
            case .failure(let error):
                if case DuplicateDetectionError.duplicateDetected = error {
                    expectation2.fulfill()
                } else {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 10)
    }
    
    func testSignatureGeneration() {
        let testImage = UIImage(named: "test_image") ?? UIImage()
        
        let expectation = expectation(description: "Signature generation")
        duplicateService.checkForDuplicate(signature: "test_signature", perceptualHash: "test_hash") { result in
            switch result {
            case .success:
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Signature check failed: \(error)")
            }
        }
        
        waitForExpectations(timeout: 5)
    }
} 
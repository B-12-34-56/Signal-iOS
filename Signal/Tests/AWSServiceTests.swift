import XCTest
import AWSS3
import AWSDynamoDB
@testable import Signal

class AWSServiceTests: XCTestCase {
    let awsService = AWSService.shared
    
    // MARK: - S3 Upload Tests
    
    func testSuccessfulImageUpload() {
        let expectation = XCTestExpectation(description: "Image upload should succeed")
        
        // Create a test image
        let testImage = createTestImage()
        
        var uploadProgress: Double = 0
        let uploadId = awsService.uploadImage(testImage, progressHandler: { progress in
            uploadProgress = progress
        }) { result in
            switch result {
            case .success(let imageURL):
                XCTAssertFalse(imageURL.isEmpty)
                XCTAssertTrue(imageURL.hasPrefix(AWSConfig.shared.s3BaseURL))
                XCTAssertTrue(uploadProgress >= 1.0)
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Upload failed with error: \(error.localizedDescription)")
            }
        }
        
        XCTAssertNotNil(uploadId)
        wait(for: [expectation], timeout: 30)
    }
    
    func testInvalidImageUpload() {
        let expectation = XCTestExpectation(description: "Invalid image should fail")
        
        // Create an invalid image (empty data)
        let invalidImage = UIImage()
        
        let uploadId = awsService.uploadImage(invalidImage) { result in
            switch result {
            case .success:
                XCTFail("Upload should have failed for invalid image")
            case .failure(let error):
                XCTAssertTrue(error is AWSServiceError)
                if case AWSServiceError.invalidImage = error {
                    expectation.fulfill()
                } else {
                    XCTFail("Expected invalidImage error, got: \(error)")
                }
            }
        }
        
        XCTAssertNil(uploadId)
        wait(for: [expectation], timeout: 10)
    }
    
    // MARK: - DynamoDB Duplicate Detection Tests
    
    func testDuplicateImageDetection() {
        let expectation = XCTestExpectation(description: "Duplicate detection should work")
        
        // First, save an image signature
        let testHash = "test_hash_\(UUID().uuidString)"
        
        awsService.saveImageSignature(hash: testHash) { result in
            switch result {
            case .success:
                // Now try to save the same hash again
                self.awsService.saveImageSignature(hash: testHash) { secondResult in
                    switch secondResult {
                    case .success:
                        XCTFail("Should have detected duplicate")
                    case .failure(let error):
                        if case AWSServiceError.duplicateImage = error {
                            expectation.fulfill()
                        } else {
                            XCTFail("Expected duplicateImage error, got: \(error)")
                        }
                    }
                }
            case .failure(let error):
                XCTFail("First save failed: \(error)")
            }
        }
        
        wait(for: [expectation], timeout: 30)
    }
    
    func testImageSignatureRetrieval() {
        let expectation = XCTestExpectation(description: "Should retrieve saved signature")
        
        let testHash = "test_hash_\(UUID().uuidString)"
        
        // First save the signature
        awsService.saveImageSignature(hash: testHash) { result in
            switch result {
            case .success:
                // Then try to retrieve it
                self.awsService.getImageSignature(hash: testHash) { getResult in
                    switch getResult {
                    case .success(let item):
                        XCTAssertNotNil(item)
                        XCTAssertEqual(item?["ContentHash"]?.s, testHash)
                        expectation.fulfill()
                    case .failure(let error):
                        XCTFail("Failed to retrieve signature: \(error)")
                    }
                }
            case .failure(let error):
                XCTFail("Failed to save signature: \(error)")
            }
        }
        
        wait(for: [expectation], timeout: 30)
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage() -> UIImage {
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
    }
} 
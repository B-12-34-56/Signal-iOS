import XCTest
import AWSS3
import AWSDynamoDB
@testable import Signal

class MainAWSTests: XCTestCase {
    let awsService = AWSService.shared
    
    override class func setUp() {
        super.setUp()
        TestConfig.setupAWS()
    }
    
    override func setUp() {
        super.setUp()
        // Ensure AWS is properly configured before running tests
        XCTAssertNotNil(AWSConfig.shared.s3BucketName, "S3 bucket name should be configured")
        XCTAssertNotNil(AWSConfig.shared.dynamoDbTableName, "DynamoDB table name should be configured")
    }
    
    func testFullAWSWorkflow() {
        let expectation = XCTestExpectation(description: "Complete AWS workflow test")
        
        // 1. Create and upload test image
        let testImage = createTestImage()
        var uploadedImageURL: String?
        
        awsService.uploadImage(testImage) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let imageURL):
                uploadedImageURL = imageURL
                print("✅ Image uploaded successfully: \(imageURL)")
                
                // 2. Generate a test hash and save it
                let testHash = "test_hash_\(UUID().uuidString)"
                self.awsService.saveImageSignature(hash: testHash) { saveResult in
                    switch saveResult {
                    case .success:
                        print("✅ Image signature saved successfully")
                        
                        // 3. Try to save the same hash (should detect duplicate)
                        self.awsService.saveImageSignature(hash: testHash) { duplicateResult in
                            switch duplicateResult {
                            case .success:
                                XCTFail("❌ Should have detected duplicate")
                            case .failure(let error):
                                if case AWSServiceError.duplicateImage = error {
                                    print("✅ Duplicate detection working correctly")
                                    
                                    // 4. Verify we can retrieve the signature
                                    self.awsService.getImageSignature(hash: testHash) { getResult in
                                        switch getResult {
                                        case .success(let item):
                                            XCTAssertNotNil(item)
                                            XCTAssertEqual(item?["ContentHash"]?.s, testHash)
                                            print("✅ Signature retrieval working correctly")
                                            expectation.fulfill()
                                        case .failure(let error):
                                            XCTFail("❌ Failed to retrieve signature: \(error)")
                                        }
                                    }
                                } else {
                                    XCTFail("❌ Expected duplicateImage error, got: \(error)")
                                }
                            }
                        }
                    case .failure(let error):
                        XCTFail("❌ Failed to save signature: \(error)")
                    }
                }
            case .failure(let error):
                XCTFail("❌ Upload failed with error: \(error.localizedDescription)")
            }
        }
        
        wait(for: [expectation], timeout: 60)
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
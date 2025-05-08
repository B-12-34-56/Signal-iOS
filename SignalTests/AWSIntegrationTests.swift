import XCTest
import AWSCore
import AWSS3
import AWSDynamoDB
@testable import Signal

class AWSIntegrationTests: XCTestCase {
    var awsConfig: AWSConfig!
    var awsService: AWSService!
    
    override func setUp() {
        super.setUp()
        do {
            awsConfig = try AWSConfig.shared
            try awsConfig.configureAWS()
            awsService = AWSService.shared
        } catch {
            XCTFail("Failed to initialize AWS configuration: \(error)")
        }
    }
    
    override func tearDown() {
        awsConfig = nil
        awsService = nil
        super.tearDown()
    }
    
    func testAWSConfiguration() {
        // Test S3 Configuration
        XCTAssertEqual(awsConfig.s3BucketName, "2314823894myawsbucket")
        XCTAssertEqual(awsConfig.s3Region, .USEast1)
        XCTAssertEqual(awsConfig.s3ImagesPath, "images")
        
        // Test DynamoDB Configuration
        XCTAssertEqual(awsConfig.dynamoDbTableName, "ImageSignatures")
        XCTAssertEqual(awsConfig.dynamoDbRegion, .USEast1)
        XCTAssertEqual(awsConfig.dynamoDbTableArn, "arn:aws:dynamodb:us-east-1:739874238091:table/ImageSignatures")
        
        // Test Cognito Configuration
        XCTAssertEqual(awsConfig.identityPoolId, "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c")
        XCTAssertEqual(awsConfig.cognitoRegion, .USEast1)
    }
    
    func testImageUpload() {
        // Create a test image
        let testImage = createTestImage()
        
        // Create expectation for upload completion
        let uploadExpectation = expectation(description: "Image upload should complete")
        var uploadProgress: Double = 0
        var uploadResult: Result<String, Error>?
        
        // Start upload
        let uploadId = awsService.uploadImage(testImage) { progress in
            uploadProgress = progress
        } completion: { result in
            uploadResult = result
            uploadExpectation.fulfill()
        }
        
        // Wait for upload to complete
        wait(for: [uploadExpectation], timeout: 30)
        
        // Verify upload results
        XCTAssertNotNil(uploadId, "Upload ID should not be nil")
        XCTAssertGreaterThan(uploadProgress, 0, "Upload progress should be greater than 0")
        
        switch uploadResult {
        case .success(let imageURL):
            XCTAssertTrue(imageURL.contains(awsConfig.s3BucketName), "Image URL should contain bucket name")
            XCTAssertTrue(imageURL.contains(awsConfig.s3ImagesPath), "Image URL should contain images path")
        case .failure(let error):
            XCTFail("Upload failed with error: \(error)")
        case .none:
            XCTFail("Upload result should not be nil")
        }
    }
    
    func testDynamoDBOperations() {
        // Create test hash
        let testHash = "test_hash_\(UUID().uuidString)"
        
        // Test saving signature
        let saveExpectation = expectation(description: "Save signature should complete")
        awsService.saveImageSignature(hash: testHash) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("Failed to save signature: \(error)")
            }
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 10)
        
        // Test retrieving signature
        let getExpectation = expectation(description: "Get signature should complete")
        awsService.getImageSignature(hash: testHash) { result in
            switch result {
            case .success(let item):
                XCTAssertNotNil(item, "Retrieved item should not be nil")
                XCTAssertEqual(item?["ContentHash"]?.s, testHash, "Retrieved hash should match saved hash")
            case .failure(let error):
                XCTFail("Failed to get signature: \(error)")
            }
            getExpectation.fulfill()
        }
        wait(for: [getExpectation], timeout: 10)
    }
    
    func testErrorHandling() {
        // Test invalid image
        let invalidImage = UIImage()
        let invalidImageExpectation = expectation(description: "Invalid image upload should fail")
        
        awsService.uploadImage(invalidImage) { _ in } completion: { result in
            switch result {
            case .success:
                XCTFail("Upload should fail for invalid image")
            case .failure(let error):
                XCTAssertTrue(error is AWSServiceError, "Error should be AWSServiceError")
            }
            invalidImageExpectation.fulfill()
        }
        
        wait(for: [invalidImageExpectation], timeout: 10)
        
        // Test duplicate image detection
        let testImage = createTestImage()
        let duplicateExpectation = expectation(description: "Duplicate image upload should be detected")
        
        // First upload
        awsService.uploadImage(testImage) { _ in } completion: { _ in
            // Second upload
            self.awsService.uploadImage(testImage) { _ in } completion: { result in
                switch result {
                case .success:
                    XCTFail("Duplicate upload should be detected")
                case .failure(let error):
                    XCTAssertTrue(error is AWSServiceError, "Error should be AWSServiceError")
                }
                duplicateExpectation.fulfill()
            }
        }
        
        wait(for: [duplicateExpectation], timeout: 30)
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
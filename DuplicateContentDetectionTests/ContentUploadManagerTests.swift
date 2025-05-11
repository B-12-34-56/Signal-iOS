import XCTest
import AWSCore
import AWSS3
import AWSDynamoDB
import Logging

@testable import DuplicateContentDetection

class ContentUploadManagerTests: XCTestCase {
    private var sut: ContentUploadManager!
    private var mockS3TransferUtility: MockS3TransferUtility!
    private var mockDynamoDB: MockDynamoDB!
    
    override func setUp() {
        super.setUp()
        
        // Configure AWS
        AWSConfig.shared.configure()
        
        // Create mock instances
        mockS3TransferUtility = MockS3TransferUtility()
        mockDynamoDB = MockDynamoDB()
        
        // Create test instance with mocks
        sut = ContentUploadManager()
    }
    
    override func tearDown() {
        sut = nil
        mockS3TransferUtility = nil
        mockDynamoDB = nil
        super.tearDown()
    }
    
    // MARK: - Test Cases
    
    func testUploadNewContent() {
        // Given
        let testData = "Test content".data(using: .utf8)!
        let contentType = "text/plain"
        let expectedHash = testData.sha256().base64EncodedString()
        
        // When
        let expectation = self.expectation(description: "Upload completion")
        var result: Result<String, Error>?
        
        sut.uploadContent(testData, contentType: contentType) { uploadResult in
            result = uploadResult
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5)
        
        // Then
        switch result {
        case .success(let s3Key):
            XCTAssertTrue(s3Key.hasPrefix(AWSConfig.s3ImagesPath))
            XCTAssertEqual(mockDynamoDB.storedSignatures[expectedHash]?.s3Key, s3Key)
        case .failure(let error):
            XCTFail("Upload failed with error: \(error)")
        case .none:
            XCTFail("No result received")
        }
    }
    
    func testDuplicateContentDetection() {
        // Given
        let testData = "Test content".data(using: .utf8)!
        let contentType = "text/plain"
        let hash = testData.sha256().base64EncodedString()
        
        // Simulate existing content in DynamoDB
        mockDynamoDB.storedSignatures[hash] = MockDynamoDB.Signature(
            s3Key: "existing-key",
            timestamp: Date().timeIntervalSince1970
        )
        
        // When
        let expectation = self.expectation(description: "Upload completion")
        var result: Result<String, Error>?
        
        sut.uploadContent(testData, contentType: contentType) { uploadResult in
            result = uploadResult
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5)
        
        // Then
        switch result {
        case .failure(let error as ContentUploadError):
            XCTAssertEqual(error, .duplicateContent)
        case .success:
            XCTFail("Should have detected duplicate content")
        case .failure(let error):
            XCTFail("Unexpected error: \(error)")
        case .none:
            XCTFail("No result received")
        }
    }
    
    func testS3UploadFailure() {
        // Given
        let testData = "Test content".data(using: .utf8)!
        let contentType = "text/plain"
        
        // Simulate S3 upload failure
        mockS3TransferUtility.shouldFail = true
        
        // When
        let expectation = self.expectation(description: "Upload completion")
        var result: Result<String, Error>?
        
        sut.uploadContent(testData, contentType: contentType) { uploadResult in
            result = uploadResult
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5)
        
        // Then
        switch result {
        case .failure(let error as ContentUploadError):
            XCTAssertEqual(error, .uploadFailed)
        case .success:
            XCTFail("Should have failed to upload")
        case .failure(let error):
            XCTFail("Unexpected error: \(error)")
        case .none:
            XCTFail("No result received")
        }
    }
}

// MARK: - Mock Classes

private class MockS3TransferUtility: AWSS3TransferUtility {
    var shouldFail = false
    
    override func uploadData(_ data: Data,
                           bucket: String,
                           key: String,
                           contentType: String,
                           expression: AWSS3TransferUtilityUploadExpression?,
                           completionHandler: AWSS3TransferUtilityUploadCompletionHandlerBlock?) -> AWSTask<AWSS3TransferUtilityUploadTask> {
        if shouldFail {
            completionHandler?(nil, NSError(domain: "MockS3Error", code: -1, userInfo: nil))
        } else {
            completionHandler?(nil, nil)
        }
        return AWSTask(result: nil)
    }
}

private class MockDynamoDB: AWSDynamoDB {
    struct Signature {
        let s3Key: String
        let timestamp: TimeInterval
    }
    
    var storedSignatures: [String: Signature] = [:]
    var shouldFail = false
    
    override func getItem(_ request: AWSDynamoDBGetItemInput) -> AWSTask<AWSDynamoDBGetItemOutput> {
        if shouldFail {
            return AWSTask(error: NSError(domain: "MockDynamoDBError", code: -1, userInfo: nil))
        }
        
        let output = AWSDynamoDBGetItemOutput()!
        if let hash = request.key?["signature"]?.s,
           let signature = storedSignatures[hash] {
            let item = AWSDynamoDBAttributeValue()!
            item.s = signature.s3Key
            output.item = ["s3Key": item]
        }
        return AWSTask(result: output)
    }
    
    override func putItem(_ request: AWSDynamoDBPutItemInput) -> AWSTask<AWSDynamoDBPutItemOutput> {
        if shouldFail {
            return AWSTask(error: NSError(domain: "MockDynamoDBError", code: -1, userInfo: nil))
        }
        
        if let hash = request.item?["signature"]?.s,
           let s3Key = request.item?["s3Key"]?.s,
           let timestamp = request.item?["timestamp"]?.n {
            storedSignatures[hash] = Signature(
                s3Key: s3Key,
                timestamp: TimeInterval(timestamp) ?? 0
            )
        }
        return AWSTask(result: AWSDynamoDBPutItemOutput()!)
    }
} 
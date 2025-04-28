//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import AWSLambda
@testable import Signal

/// Tests for the LambdaService class to validate AWS Lambda interaction functionality
class LambdaServiceTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockClient: AWSLambdaMockClient!
    private var service: TestableLambdaService!
    private let defaultRetryCount = 3
    private let testFunctionName = "signal-content-processor"
    
    // Test data for various Lambda invocations
    private let smallImageData = Data("small test image".utf8)
    private let largeImageData = Data(repeating: 0xAB, count: 1024 * 100) // 100KB
    private let testHash = "TestHashValue123456789AbCdEf=="
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        mockClient = AWSLambdaMockClient.shared
        mockClient.reset()
        service = TestableLambdaService(mockClient: mockClient)
    }
    
    override func tearDown() async throws {
        mockClient = nil
        service = nil
        super.tearDown()
    }
    
    // MARK: - Image Processing Tests
    
    func testProcessImage_SuccessfulInvocation() async {
        // Arrange
        let metadata = ["userId": "testUser123", "purpose": "profile"]
        let expectedResult = ContentProcessingResult(
            success: true,
            status: "completed",
            contentHash: "SampleHashValue==",
            detectedIssues: nil,
            confidenceScore: 98.5,
            resultData: ["format": "jpeg", "dimensions": "100x100"],
            errorMessage: nil
        )
        
        mockClient.setResponseForFunction(testFunctionName, response: expectedResult)
        
        // Act
        let result = await service.processImage(imageData: smallImageData, metadata: metadata)
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.success, expectedResult.success)
        XCTAssertEqual(result?.contentHash, expectedResult.contentHash)
        XCTAssertEqual(result?.confidenceScore, expectedResult.confidenceScore)
        XCTAssertEqual(mockClient.getOperationCount(type: .invoke), 1)
        
        // Verify request payload contained image data and metadata
        let operation = mockClient.getOperationLog().first { $0.type == .invoke }
        XCTAssertNotNil(operation)
        XCTAssertTrue(operation?.payload.contains("imageProcessing") ?? false)
        XCTAssertTrue(operation?.payload.contains("testUser123") ?? false)
    }
    
    func testProcessImage_LargeImage() async {
        // Arrange
        let metadata = ["purpose": "story"]
        
        let expectedResult = ContentProcessingResult(
            success: true,
            status: "completed",
            contentHash: "LargeImageHash==",
            detectedIssues: nil,
            confidenceScore: 95.0,
            resultData: nil,
            errorMessage: nil
        )
        
        mockClient.setResponseForFunction(testFunctionName, response: expectedResult)
        
        // Act
        let result = await service.processImage(imageData: largeImageData, metadata: metadata)
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.success, true)
        
        // Verify the large image was properly handled
        let operation = mockClient.getOperationLog().first { $0.type == .invoke }
        XCTAssertNotNil(operation)
        // Image size should be included in the payload
        XCTAssertTrue(operation?.payload.contains(String(largeImageData.count)) ?? false)
    }
    
    // MARK: - S3 Processing Tests
    
    func testProcessAttachmentFromS3_SuccessfulInvocation() async {
        // Arrange
        let s3Key = "uploads/test-attachment.jpg"
        let metadata = ["messageId": "msg123", "origin": "direct-message"]
        
        let expectedResult = ContentProcessingResult(
            success: true,
            status: "completed",
            contentHash: "S3AttachmentHash==",
            detectedIssues: nil,
            confidenceScore: 97.2,
            resultData: ["type": "image", "processedAt": ISO8601DateFormatter().string(from: Date())],
            errorMessage: nil
        )
        
        mockClient.setResponseForFunction(testFunctionName, response: expectedResult)
        
        // Act
        let result = await service.processAttachmentFromS3(s3Key: s3Key, metadata: metadata)
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.status, "completed")
        XCTAssertEqual(result?.contentHash, expectedResult.contentHash)
        
        // Verify correct payload format
        let operation = mockClient.getOperationLog().first { $0.type == .invoke }
        XCTAssertNotNil(operation)
        XCTAssertTrue(operation?.payload.contains("s3Processing") ?? false)
        XCTAssertTrue(operation?.payload.contains(s3Key) ?? false)
        XCTAssertTrue(operation?.payload.contains("msg123") ?? false)
    }
    
    // MARK: - Hash Validation Tests
    
    func testValidateContentHash_HashAllowed() async {
        // Arrange
        let expectedResult = ContentValidationResult(
            success: true,
            status: "allowed",
            contentHash: testHash,
            detectedIssues: [],
            confidenceScore: 100.0,
            resultData: nil,
            errorMessage: nil
        )
        
        mockClient.setResponseForFunction(testFunctionName, response: expectedResult)
        
        // Act
        let result = await service.validateContentHash(testHash)
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.status, "allowed")
        
        // Verify correct payload format
        let operation = mockClient.getOperationLog().first { $0.type == .invoke }
        XCTAssertNotNil(operation)
        XCTAssertTrue(operation?.payload.contains("hashValidation") ?? false)
        XCTAssertTrue(operation?.payload.contains(testHash) ?? false)
    }
    
    func testValidateContentHash_HashBlocked() async {
        // Arrange
        let expectedResult = ContentValidationResult(
            success: true,
            status: "blocked",
            contentHash: testHash,
            detectedIssues: ["policy_violation"],
            confidenceScore: 99.8,
            resultData: ["category": "harmful_content"],
            errorMessage: nil
        )
        
        mockClient.setResponseForFunction(testFunctionName, response: expectedResult)
        
        // Act
        let result = await service.validateContentHash(testHash)
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.status, "blocked")
        XCTAssertEqual(result?.detectedIssues, ["policy_violation"])
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorHandling_ServiceUnavailable() async {
        // Arrange
        let metadata = ["test": "error_case"]
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSLambdaErrorDomain,
            code: AWSLambdaErrorType.serviceException.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Service Unavailable"]
        ))
        
        // Act
        let result = await service.processImage(imageData: smallImageData, metadata: metadata)
        
        // Assert
        XCTAssertNil(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .invoke), defaultRetryCount)
    }
    
    func testErrorHandling_ThrottledException() async {
        // Arrange
        let metadata = ["test": "throttle_case"]
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSLambdaErrorDomain,
            code: AWSLambdaErrorType.tooManyRequestsException.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Rate exceeded"]
        ))
        mockClient.setRetrySuccessAfter(attempts: 2)
        
        // Set expected result for successful retry
        let expectedResult = ContentProcessingResult(
            success: true,
            status: "completed",
            contentHash: "RetryHash==",
            detectedIssues: nil,
            confidenceScore: 85.0,
            resultData: nil,
            errorMessage: nil
        )
        mockClient.setResponseForFunction(testFunctionName, response: expectedResult)
        
        // Act
        let result = await service.processImage(imageData: smallImageData, metadata: metadata)
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(mockClient.getOperationCount(type: .invoke), 2)
    }
    
    func testErrorHandling_FunctionError() async {
        // Arrange
        mockClient.setFunctionError("Unhandled")
        
        // Act
        let result = await service.validateContentHash(testHash)
        
        // Assert
        XCTAssertNil(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .invoke), defaultRetryCount)
    }
    
    func testErrorHandling_InvalidPayload() async {
        // Arrange
        mockClient.setInvalidResponsePayload(true)
        
        // Act
        let result = await service.validateContentHash(testHash)
        
        // Assert
        XCTAssertNil(result)
    }
    
    // MARK: - Timeout Tests
    
    func testTimeout_SlowResponse() async {
        // Arrange
        mockClient.setSimulatedDelay(2.0) // 2 second delay
        
        // Lambda configuration has a 30-second timeout, so this should still succeed
        let expectedResult = ContentProcessingResult(
            success: true,
            status: "completed",
            contentHash: "DelayedHash==",
            detectedIssues: nil,
            confidenceScore: 90.0,
            resultData: nil,
            errorMessage: nil
        )
        mockClient.setResponseForFunction(testFunctionName, response: expectedResult)
        
        // Act - process should still succeed despite delay
        let result = await service.validateContentHash(testHash)
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.contentHash, "DelayedHash==")
    }
    
    func testTimeout_ExcessiveDelay() async {
        // Arrange - set delay beyond the default timeout
        mockClient.setSimulatedDelay(35.0) // 35 seconds (beyond default 30s timeout)
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        ))
        
        // Act
        let result = await service.validateContentHash(testHash)
        
        // Assert
        XCTAssertNil(result)
    }
}

// MARK: - Mock Lambda Client for Testing

class AWSLambdaMockClient: AWSLambda {
    
    // MARK: - Singleton
    
    static let shared = AWSLambdaMockClient()
    
    // MARK: - Properties
    
    private var operationLog: [Operation] = []
    private var simulatedDelay: TimeInterval = 0.0
    private var shouldFailOperations = false
    private var customError: NSError?
    private var retrySuccessAfterAttempt: Int?
    private var currentAttemptCount: [String: Int] = [:]
    private var functionResponses: [String: Any] = [:]
    private var functionError: String?
    private var invalidResponsePayload = false
    
    // MARK: - Configuration Methods
    
    func reset() {
        operationLog = []
        shouldFailOperations = false
        customError = nil
        simulatedDelay = 0.0
        retrySuccessAfterAttempt = nil
        currentAttemptCount = [:]
        functionResponses = [:]
        functionError = nil
        invalidResponsePayload = false
    }
    
    func setSimulatedDelay(_ seconds: TimeInterval) {
        simulatedDelay = seconds
    }
    
    func setFailureMode(shouldFail: Bool, error: NSError? = nil) {
        shouldFailOperations = shouldFail
        customError = error
    }
    
    func setRetrySuccessAfter(attempts: Int) {
        retrySuccessAfterAttempt = attempts
    }
    
    func setResponseForFunction<T: Encodable>(_ functionName: String, response: T) {
        do {
            let jsonData = try JSONEncoder().encode(response)
            functionResponses[functionName] = jsonData
        } catch {
            print("Failed to encode mock response: \(error)")
        }
    }
    
    func setFunctionError(_ errorType: String) {
        functionError = errorType
    }
    
    func setInvalidResponsePayload(_ invalid: Bool) {
        invalidResponsePayload = invalid
    }
    
    // MARK: - Tracking Methods
    
    func getOperationLog() -> [Operation] {
        return operationLog
    }
    
    func getOperationCount(type: OperationType) -> Int {
        return operationLog.filter { $0.type == type }.count
    }
    
    // MARK: - Lambda Operation Overrides
    
    override func invoke(_ request: AWSLambdaInvocationRequest) -> AWSTask<AWSLambdaInvocationResponse> {
        let operationType: OperationType = .invoke
        let functionName = request.functionName ?? "unknown-function"
        let payload = String(data: request.payload ?? Data(), encoding: .utf8) ?? "{}"
        
        operationLog.append(Operation(
            type: operationType,
            functionName: functionName,
            payload: payload
        ))
        
        incrementAttemptCount(for: functionName)
        
        // Handle retry success cases
        if let retrySuccessAfter = retrySuccessAfterAttempt,
           let attempts = currentAttemptCount[functionName],
           shouldFailOperations && attempts <= retrySuccessAfter {
            return AWSTask(error: customError ?? NSError(
                domain: AWSLambdaErrorDomain,
                code: AWSLambdaErrorType.serviceException.rawValue,
                userInfo: nil
            ))
        }
        
        // Handle general failure mode
        if shouldFailOperations {
            return AWSTask(error: customError ?? NSError(
                domain: AWSLambdaErrorDomain,
                code: AWSLambdaErrorType.serviceException.rawValue,
                userInfo: nil
            ))
        }
        
        // Simulate network delay
        if simulatedDelay > 0 {
            Thread.sleep(forTimeInterval: simulatedDelay)
        }
        
        // Create response
        let response = AWSLambdaInvocationResponse()
        
        // Set function error if specified
        if let functionError = functionError {
            response.functionError = functionError
        }
        
        // Set response payload
        if invalidResponsePayload {
            // Create invalid JSON data
            response.payload = "{ invalid_json: true".data(using: .utf8)
        } else if let responseData = functionResponses[functionName] as? Data {
            response.payload = responseData
        } else {
            // Default empty JSON response
            response.payload = "{}".data(using: .utf8)
        }
        
        return AWSTask(result: response)
    }
    
    // MARK: - Helper Methods
    
    private func incrementAttemptCount(for key: String) {
        currentAttemptCount[key] = (currentAttemptCount[key] ?? 0) + 1
    }
    
    // MARK: - Types
    
    enum OperationType: String {
        case invoke
    }
    
    struct Operation {
        let id: UUID = UUID()
        let type: OperationType
        let functionName: String
        let payload: String
        let timestamp = Date()
    }
}

// MARK: - Testable LambdaService Subclass

class TestableLambdaService: LambdaService {
    private let mockClient: AWSLambda
    
    init(mockClient: AWSLambda) {
        self.mockClient = mockClient
        super.init()
        
        // Override the AWS client using runtime configuration
        let clientIvar = class_getInstanceVariable(LambdaService.self, "_client")
        if let clientIvar = clientIvar {
            object_setIvar(self, clientIvar, mockClient)
        }
    }
}
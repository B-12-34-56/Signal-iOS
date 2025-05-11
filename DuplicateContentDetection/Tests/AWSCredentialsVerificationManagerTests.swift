import XCTest
import SignalServiceKit
import AWSCore
import AWSDynamoDB
import AWSS3
@testable import DuplicateContentDetection
import Logging

class AWSCredentialsVerificationManagerTests: XCTestCase {
    // MARK: - Properties
    
    private var verificationManager: AWSCredentialsVerificationManager!
    private var mockConnectionManager: MockConnectionManager!
    private var mockCredentialCache: MockCredentialCache!
    
    // MARK: - Setup
    
    override func setUp() async throws {
        try await super.setUp()
        
        mockConnectionManager = MockConnectionManager()
        mockCredentialCache = MockCredentialCache()
        
        verificationManager = AWSCredentialsVerificationManager(
            connectionManager: mockConnectionManager,
            credentialCache: mockCredentialCache
        )
    }
    
    // MARK: - Tests
    
    func testVerifyValidCredentials() async throws {
        // Setup
        let testCredentials = AWSCredentials(
            accessKey: "test-key",
            secretKey: "test-secret",
            sessionToken: "test-token",
            expiration: Date().addingTimeInterval(3600)
        )
        mockCredentialCache.mockCredentials = testCredentials
        mockConnectionManager.mockResponse = true
        
        // Execute
        let isValid = try await verificationManager.verifyCredentials(for: "S3")
        
        // Verify
        XCTAssertTrue(isValid)
        XCTAssertEqual(mockConnectionManager.lastServiceName, "S3")
        XCTAssertEqual(mockConnectionManager.lastOperationName, "VerifyCredentials")
        
        // Check cached result
        let status = verificationManager.getVerificationStatus(for: "S3")
        XCTAssertNotNil(status)
        XCTAssertTrue(status?.isValid ?? false)
    }
    
    func testVerifyInvalidCredentials() async throws {
        // Setup
        let testCredentials = AWSCredentials(
            accessKey: "test-key",
            secretKey: "test-secret",
            sessionToken: "test-token",
            expiration: Date().addingTimeInterval(3600)
        )
        mockCredentialCache.mockCredentials = testCredentials
        mockConnectionManager.mockResponse = false
        
        // Execute & Verify
        do {
            _ = try await verificationManager.verifyCredentials(for: "S3")
            XCTFail("Should have thrown verification failed error")
        } catch let error as AWSCredentialsVerificationError {
            XCTAssertEqual(error, .verificationFailed)
        }
        
        // Check cached result
        let status = verificationManager.getVerificationStatus(for: "S3")
        XCTAssertNotNil(status)
        XCTAssertFalse(status?.isValid ?? true)
    }
    
    func testMissingCredentials() async throws {
        // Setup
        mockCredentialCache.mockCredentials = nil
        
        // Execute & Verify
        do {
            _ = try await verificationManager.verifyCredentials(for: "S3")
            XCTFail("Should have thrown missing credentials error")
        } catch let error as AWSCredentialsVerificationError {
            XCTAssertEqual(error, .missingCredentials)
        }
    }
    
    func testVerifyAllCredentials() async throws {
        // Setup
        let testCredentials = AWSCredentials(
            accessKey: "test-key",
            secretKey: "test-secret",
            sessionToken: "test-token",
            expiration: Date().addingTimeInterval(3600)
        )
        mockCredentialCache.mockCredentials = testCredentials
        mockConnectionManager.mockResponse = true
        
        // Execute
        try await verificationManager.verifyAllCredentials()
        
        // Verify
        let services = ["S3", "DynamoDB", "Lambda", "APIGateway"]
        for service in services {
            let status = verificationManager.getVerificationStatus(for: service)
            XCTAssertNotNil(status)
            XCTAssertTrue(status?.isValid ?? false)
        }
    }
    
    func testVerificationCacheTimeout() async throws {
        // Setup
        let testCredentials = AWSCredentials(
            accessKey: "test-key",
            secretKey: "test-secret",
            sessionToken: "test-token",
            expiration: Date().addingTimeInterval(3600)
        )
        mockCredentialCache.mockCredentials = testCredentials
        mockConnectionManager.mockResponse = true
        
        // First verification
        _ = try await verificationManager.verifyCredentials(for: "S3")
        
        // Wait for cache to expire
        try await Task.sleep(nanoseconds: 31_000_000_000)
        
        // Second verification should trigger a new verification
        _ = try await verificationManager.verifyCredentials(for: "S3")
        
        // Verify
        XCTAssertEqual(mockConnectionManager.attemptCount, 2)
    }
    
    func testConcurrentVerifications() async throws {
        // Setup
        let testCredentials = AWSCredentials(
            accessKey: "test-key",
            secretKey: "test-secret",
            sessionToken: "test-token",
            expiration: Date().addingTimeInterval(3600)
        )
        mockCredentialCache.mockCredentials = testCredentials
        mockConnectionManager.mockResponse = true
        
        // Execute concurrent verifications
        async let verification1 = verificationManager.verifyCredentials(for: "S3")
        async let verification2 = verificationManager.verifyCredentials(for: "DynamoDB")
        async let verification3 = verificationManager.verifyCredentials(for: "Lambda")
        
        let results = try await [verification1, verification2, verification3]
        
        // Verify
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(mockConnectionManager.attemptCount, 3)
    }
}

// MARK: - Mock Types

private class MockConnectionManager: AWSConnectionManager {
    var mockResponse: Any?
    var attemptCount = 0
    var lastServiceName: String?
    var lastOperationName: String?
    
    override func executeWithRetry<T>(
        _ operation: () async throws -> T,
        serviceName: String,
        operationName: String
    ) async throws -> T {
        lastServiceName = serviceName
        lastOperationName = operationName
        attemptCount += 1
        
        if let response = mockResponse as? T {
            return response
        }
        
        throw NSError(domain: "Test", code: -1)
    }
}

private class MockCredentialCache: AWSCredentialCache {
    var mockCredentials: AWSCredentials?
    
    override func getCredentials(forService service: String) throws -> AWSCredentials? {
        return mockCredentials
    }
}

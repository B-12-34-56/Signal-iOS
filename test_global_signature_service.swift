//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import AWSDynamoDB
@testable import SignalServiceKit

/// Tests that validate the GlobalSignatureService implementation's functionality,
/// error handling, and retry mechanisms when interacting with DynamoDB.
class GlobalSignatureServiceTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockClient: AWSMockClient!
    private var service: GlobalSignatureService!
    private var defaultRetryCount = 3
    private var testTableName = AWSConfig.dynamoDbTableName
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        mockClient = AWSMockClientFactory.createMockClient()
        service = TestableGlobalSignatureService(mockClient: mockClient)
    }
    
    override func tearDown() async throws {
        mockClient = nil
        service = nil
        super.tearDown()
    }
    
    // MARK: - Test Hash Checking
    
    func testContains_HashExists_ReturnsTrue() async {
        // Arrange
        let testHash = "testHash123"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1)
    }
    
    func testContains_HashDoesNotExist_ReturnsFalse() async {
        // Arrange
        let testHash = "nonexistentHash"
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertFalse(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1)
    }
    
    func testContains_EmptyString_ReturnsFalse() async {
        // Arrange
        let testHash = ""
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertFalse(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1)
    }
    
    // MARK: - Test Hash Storage
    
    func testStore_NewHash_StoresSuccessfully() async {
        // Arrange
        let testHash = "newHash123"
        let timestamp = Date()
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result)
        let stored = await service.contains(testHash)
        XCTAssertTrue(stored)
        
        // Verify TTL was set correctly
        let ttl = mockClient.getStoredTTL(for: testHash)
        XCTAssertNotNil(ttl)
        let expectedTTL = Int(timestamp.timeIntervalSince1970) + (AWSConfig.defaultTTLInDays * 24 * 60 * 60)
        XCTAssertEqual(ttl, expectedTTL, accuracy: 60.0) // Allow 1 minute variance
    }
    
    func testStore_DuplicateHash_ReturnsTrue() async {
        // Arrange
        let testHash = "duplicateHash"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .putItem), 1)
    }
    
    func testStore_EmptyString_StillStores() async {
        // Arrange
        let testHash = ""
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result)
        let stored = await service.contains(testHash)
        XCTAssertTrue(stored)
    }
    
    // MARK: - Test Error Handling
    
    func testContains_WithThrottlingError_Retries() async {
        // Arrange
        let testHash = "retriableHash"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.throttlingException.rawValue,
            userInfo: nil
        ))
        mockClient.setRetrySuccessAfter(attempts: 2)
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 2)
    }
    
    func testStore_WithNetworkError_RetriesAndFails() async {
        // Arrange
        let testHash = "networkErrorHash"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: nil
        ))
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertFalse(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .putItem), defaultRetryCount)
    }
    
    // MARK: - Test Retry Logic
    
    func testRetryLogic_ExponentialBackoff() async {
        // Arrange
        let testHash = "backoffHash"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.throttlingException.rawValue,
            userInfo: nil
        ))
        
        // Act
        let startTime = Date()
        _ = await service.contains(testHash)
        let duration = Date().timeIntervalSince(startTime)
        
        // Assert
        let expectedMinDelay = pow(2.0, Double(defaultRetryCount - 1)) * 0.75 // Minimum with jitter
        XCTAssertGreaterThan(duration, expectedMinDelay)
    }
    
    // MARK: - Test Edge Cases
    
    func testContains_VeryLongHash_Succeeds() async {
        // Arrange
        let testHash = String(repeating: "a", count: 1000)
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertTrue(result)
    }
    
    func testStore_WithSpecialCharacters_Succeeds() async {
        // Arrange
        let testHash = "hash!@#$%^&*()"
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result)
        let stored = await service.contains(testHash)
        XCTAssertTrue(stored)
    }
}

// MARK: - Test Helper Classes

class TestableGlobalSignatureService: GlobalSignatureService {
    private let mockClient: AWSDynamoDB
    
    init(mockClient: AWSDynamoDB) {
        self.mockClient = mockClient
        super.init()
        
        // Override the AWS client using runtime configuration
        let clientIvar = class_getInstanceVariable(GlobalSignatureService.self, "_client")
        if let clientIvar = clientIvar {
            object_setIvar(self, clientIvar, mockClient)
        }
    }
}
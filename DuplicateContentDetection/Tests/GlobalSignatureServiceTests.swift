//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import AWSDynamoDB
@testable import DuplicateContentDetection

class GlobalSignatureServiceTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockClient: AWSMockClient!
    private var service: TestableGlobalSignatureService!
    private let testTableName = AWSConfig.dynamoDbTableName
    private let testHashFieldName = AWSConfig.hashFieldName
    private let testTimestampFieldName = AWSConfig.timestampFieldName
    private let testTTLFieldName = AWSConfig.ttlFieldName
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        // Create a fresh mock client for each test to ensure isolation
        mockClient = AWSMockClientFactory.createMockClient()
        
        // Create a testable service using our mock client
        service = TestableGlobalSignatureService(mockClient: mockClient)
    }
    
    override func tearDown() async throws {
        mockClient = nil
        service = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func generateRandomHash(length: Int = 32) -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        var randomString = ""
        for _ in 0..<length {
            let randomIndex = Int.random(in: 0..<characters.count)
            let randomCharacter = characters[characters.index(characters.startIndex, offsetBy: randomIndex)]
            randomString.append(randomCharacter)
        }
        return randomString
    }
    
    private func generateLongHash(length: Int = 1000) -> String {
        return String(repeating: "A", count: length)
    }
    
    // MARK: - Tests for contains() Method
    
    func testContains_ExistingHash_ReturnsTrue() async {
        // Arrange
        let testHash = "ExistingHash123"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should return true for an existing hash")
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1, "Should make exactly one getItem call")
    }
    
    func testContains_NonExistingHash_ReturnsFalse() async {
        // Arrange
        let testHash = "NonExistingHash123"
        // Don't add the hash to the mock database
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertFalse(result, "Should return false for a non-existing hash")
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1, "Should make exactly one getItem call")
    }
    
    func testContains_EmptyString_ReturnsFalse() async {
        // Arrange
        let emptyHash = ""
        
        // Act
        let result = await service.contains(emptyHash)
        
        // Assert
        XCTAssertFalse(result, "Should return false for an empty hash string")
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1, "Should make exactly one getItem call")
    }
    
    func testContains_WithSpecialCharacters_ProcessesCorrectly() async {
        // Arrange
        let specialHash = "Special#Hash@123!+"
        mockClient.populateWithHashes([specialHash])
        
        // Act
        let result = await service.contains(specialHash)
        
        // Assert
        XCTAssertTrue(result, "Should handle special characters correctly")
        
        // Verify the exact hash was queried
        let operations = mockClient.getOperationLog().filter { $0.type == .getItem }
        XCTAssertEqual(operations.first?.key, specialHash, "The exact hash with special characters should be queried")
    }
    
    // MARK: - Tests for store() Method
    
    func testStore_NewHash_StoresSuccessfully() async {
        // Arrange
        let testHash = "NewHash123"
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should return true on successful store")
        XCTAssertEqual(mockClient.getOperationCount(type: .putItem), 1, "Should make exactly one putItem call")
        
        // Verify hash was stored
        let storedResult = await service.contains(testHash)
        XCTAssertTrue(storedResult, "Hash should be found after storing")
    }
    
    func testStore_ExistingHash_ReturnsTrue() async {
        // Arrange
        let testHash = "ExistingHash123"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should return true even if hash already exists")
        
        // Verify conditional check failed error was handled correctly
        let operations = mockClient.getOperationLog().filter { $0.type == .putItem }
        XCTAssertEqual(operations.count, 1, "Should make exactly one putItem call despite existing hash")
    }
    
    func testStore_VerifyTTLSet() async {
        // Arrange
        let testHash = "HashWithTTL"
        let now = Date()
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should successfully store the hash")
        
        // Verify TTL was set correctly
        let ttl = mockClient.getStoredTTL(for: testHash)
        XCTAssertNotNil(ttl, "TTL should be set")
        
        if let ttl = ttl {
            let expectedTTL = Int(now.timeIntervalSince1970) + (AWSConfig.defaultTTLInDays * 24 * 60 * 60)
            // Allow 5 second variance for test execution time
            XCTAssertEqual(ttl, expectedTTL, accuracy: 5.0, "TTL should be set to current time + TTL days")
        }
    }
    
    // MARK: - Tests for delete() Method
    
    func testDelete_ExistingHash_DeletesSuccessfully() async {
        // Arrange
        let testHash = "HashToDelete"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.delete(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should return true on successful delete")
        XCTAssertEqual(mockClient.getOperationCount(type: .deleteItem), 1, "Should make exactly one deleteItem call")
        
        // Verify hash was deleted
        let containsResult = await service.contains(testHash)
        XCTAssertFalse(containsResult, "Hash should not be found after deletion")
    }
    
    func testDelete_NonExistentHash_StillReturnsTrue() async {
        // Arrange
        let testHash = "NonExistentHashToDelete"
        // Don't populate the hash
        
        // Act
        let result = await service.delete(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should return true even for non-existent hash")
        XCTAssertEqual(mockClient.getOperationCount(type: .deleteItem), 1, "Should make exactly one deleteItem call")
    }
    
    // MARK: - Tests for Retry Logic
    
    func testRetryLogic_ForThrottlingError_EventuallySucceeds() async {
        // Arrange
        let testHash = "RetryHash"
        mockClient.populateWithHashes([testHash])
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.throttlingException.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Throttling Exception"]
        ))
        mockClient.setRetrySuccessAfter(attempts: 2)
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should eventually succeed after retries")
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 2, "Should have made 2 attempts")
    }
    
    func testRetryLogic_ForNetworkError_EventuallySucceeds() async {
        // Arrange
        let testHash = "NetworkErrorHash"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "Network Connection Lost"]
        ))
        mockClient.setRetrySuccessAfter(attempts: 2)
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result, "Should eventually succeed after retries")
        XCTAssertEqual(mockClient.getOperationCount(type: .putItem), 2, "Should have made 2 attempts")
    }
    
    func testRetryLogic_ExhaustsRetries_ThenFails() async {
        // Arrange
        let testHash = "FailingHash"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.throttlingException.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Persistent Throttling"]
        ))
        // Don't set retrySuccessAfter to ensure all attempts fail
        
        // Act
        let result = await service.contains(testHash, retryCount: 3)
        
        // Assert
        XCTAssertFalse(result, "Should fail after exhausting retries")
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 3, "Should have made exactly 3 attempts")
    }
    
    func testRetryLogic_NonRetryableError_FailsImmediately() async {
        // Arrange
        let testHash = "NonRetryableHash"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.accessDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Access Denied"]
        ))
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertFalse(result, "Should fail immediately for non-retryable errors")
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1, "Should make only one attempt")
    }
    
    // MARK: - Tests for Edge Cases and Error Handling
    
    func testWithLongHash_HandlesCorrectly() async {
        // Arrange
        let longHash = generateLongHash(length: 1000)
        
        // Act
        let storeResult = await service.store(longHash)
        let containsResult = await service.contains(longHash)
        let deleteResult = await service.delete(longHash)
        
        // Assert
        XCTAssertTrue(storeResult, "Should handle storing very long hash")
        XCTAssertTrue(containsResult, "Should handle checking very long hash")
        XCTAssertTrue(deleteResult, "Should handle deleting very long hash")
    }
    
    func testConcurrentOperations_HandlesCorrectly() async {
        // Arrange
        let hashes = (0..<10).map { _ in generateRandomHash() }
        
        // Act - perform operations concurrently
        await withTaskGroup(of: Bool.self) { group in
            for hash in hashes {
                group.addTask {
                    // Store and then check
                    let stored = await self.service.store(hash)
                    let exists = await self.service.contains(hash)
                    return stored && exists
                }
            }
            
            // Collect results
            var results = [Bool]()
            for await result in group {
                results.append(result)
            }
            
            // Assert all operations succeeded
            XCTAssertEqual(results.count, hashes.count)
            XCTAssertTrue(results.allSatisfy { $0 }, "All concurrent operations should succeed")
        }
    }
    
    func testRequestFormatting_Contains() async {
        // Arrange
        let testHash = "RequestFormatHash"
        
        // Act
        _ = await service.contains(testHash)
        
        // Assert
        let operations = mockClient.getOperationLog().filter { $0.type == .getItem }
        XCTAssertEqual(operations.count, 1)
        
        let operation = operations.first
        XCTAssertEqual(operation?.tableName, testTableName)
        XCTAssertEqual(operation?.key, testHash)
    }
    
    func testRequestFormatting_Store() async {
        // Arrange
        let testHash = "StoreFormatHash"
        
        // Act
        _ = await service.store(testHash)
        
        // Assert
        let operations = mockClient.getOperationLog().filter { $0.type == .putItem }
        XCTAssertEqual(operations.count, 1)
        
        let operation = operations.first
        XCTAssertEqual(operation?.tableName, testTableName)
        XCTAssertEqual(operation?.key, testHash)
        
        // Verify the item has all required attributes
        let item = operation?.item
        XCTAssertNotNil(item?[testHashFieldName])
        XCTAssertNotNil(item?[testTimestampFieldName])
        XCTAssertNotNil(item?[testTTLFieldName])
    }
}

// MARK: - Test Helpers

/// A testable subclass of GlobalSignatureService that allows injection of a mock client
class TestableGlobalSignatureService: GlobalSignatureService {
    private let mockClient: AWSDynamoDB
    
    init(mockClient: AWSDynamoDB) {
        self.mockClient = mockClient
        super.init()
        
        // Override the client property using Objective-C runtime
        let clientIvar = class_getInstanceVariable(GlobalSignatureService.self, "_client")
        if let clientIvar = clientIvar {
            object_setIvar(self, clientIvar, mockClient)
        }
    }
}

/// Extension to add aws_await for testing
extension AWSTask {
    // This extension needs to be implemented if not already available
    // The mock client refers to this method
    func aws_await() async throws -> Result {
        return try await withCheckedThrowingContinuation { continuation in
            self.continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else if let exception = task.exception {
                    continuation.resume(throwing: NSError(
                        domain: "AWSTaskException",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Task threw exception: \(exception)"]
                    ))
                } else if let result = task.result as? Result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AWSTaskError",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Task completed with no result"]
                    ))
                }
                return nil
            }
        }
    }
}
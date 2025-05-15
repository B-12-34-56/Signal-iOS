//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
import AWSCore
import AWSDynamoDB
@testable import SignalServiceKit

class GlobalSignatureServiceTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockClient: AWSMockClient!
    private var service: GlobalSignatureService!
    private let testTableName = AWSConfig.dynamoDbTableName
    private let testHashFieldName = AWSConfig.hashFieldName
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        // Create a new mock client for each test
        mockClient = AWSMockClientFactory.createMockClient()
        
        // Create a testable subclass that uses our mock client
        service = TestableGlobalSignatureService(mockClient: mockClient)
    }
    
    override func tearDown() async throws {
        mockClient = nil
        service = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func generateRandomHash() -> String {
        let randomData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return randomData.base64EncodedString()
    }
    
    // MARK: - Tests for Hash Checking
    
    func testContains_HashExists_ReturnsTrue() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1)
    }
    
    func testContains_HashDoesNotExist_ReturnsFalse() async {
        // Arrange
        let testHash = "TestHash123"
        // Don't populate DB with the hash
        
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
    
    func testContains_WithServerError_ReturnsFalse() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.internalServerError.rawValue,
            userInfo: nil
        ))
        
        // Act
        let result = await service.contains(testHash)
        
        // Assert
        XCTAssertFalse(result)
    }
    
    func testContains_WithRetryableError_RetriesThenSucceeds() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.populateWithHashes([testHash])
        
        // Configure mock to fail on first attempt, then succeed
        var requestCount = 0
        let originalGetItem = mockClient.getItem
        mockClient.getItem = { getItemInput in
            requestCount += 1
            if requestCount == 1 {
                // First request fails with throttling error
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.throttlingException.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Throttling Exception"]
                )
                return AWSTask(error: error)
            } else {
                // Subsequent requests succeed
                return originalGetItem(getItemInput)
            }
        }
        
        // Act
        let result = await service.contains(testHash, retryCount: 3)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(requestCount, 2, "Should have tried twice (first fails, second succeeds)")
    }
    
    func testContains_WithRetryableError_ExhaustsRetries() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.throttlingException.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Throttling Exception"]
        ))
        
        // Act
        let result = await service.contains(testHash, retryCount: 3)
        
        // Assert
        XCTAssertFalse(result)
    }
    
    // MARK: - Tests for Hash Storage
    
    func testStore_NewHash_StoresSuccessfully() async {
        // Arrange
        let testHash = "TestHash123"
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .putItem), 1)
        
        // Verify hash was stored
        let contains = await service.contains(testHash)
        XCTAssertTrue(contains)
    }
    
    func testStore_ExistingHash_ReturnsSuccess() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result)
    }
    
    func testStore_VerifyTTLField() async {
        // Arrange
        let testHash = "TestHash123"
        
        // Act
        _ = await service.store(testHash)
        
        // Assert
        let operations = mockClient.getOperationLog().filter { $0.type == .putItem }
        XCTAssertEqual(operations.count, 1)
        
        // Check if item exists with TTL field
        let now = Date()
        let expectedTTLRangeStart = Int(now.timeIntervalSince1970) + (AWSConfig.defaultTTLInDays * 24 * 60 * 60) - 60 // Allow 1 min variation
        let expectedTTLRangeEnd = expectedTTLRangeStart + 120 // 2 min range
        
        guard let getItemInput = AWSDynamoDBGetItemInput() else {
            XCTFail("Failed to create GetItemInput")
            return
        }
        
        getItemInput.tableName = testTableName
        
        guard let hashAttr = AWSDynamoDBAttributeValue() else {
            XCTFail("Failed to create hash AttributeValue")
            return
        }
        
        hashAttr.s = testHash
        getItemInput.key = [testHashFieldName: hashAttr]
        
        do {
            let output = try await mockClient.getItem(getItemInput)
            guard let item = output.item, let ttlAttr = item[AWSConfig.ttlFieldName], let ttlString = ttlAttr.n else {
                XCTFail("Item doesn't have TTL field")
                return
            }
            
            guard let ttl = Int(ttlString) else {
                XCTFail("TTL is not a valid number")
                return
            }
            
            XCTAssertGreaterThanOrEqual(ttl, expectedTTLRangeStart)
            XCTAssertLessThanOrEqual(ttl, expectedTTLRangeEnd)
        } catch {
            XCTFail("Error retrieving item: \(error)")
        }
    }
    
    func testStore_WithServerError_ReturnsFalse() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.internalServerError.rawValue,
            userInfo: nil
        ))
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertFalse(result)
    }
    
    func testStore_EmptyString_StillStores() async {
        // Arrange
        let testHash = ""
        
        // Act
        let result = await service.store(testHash)
        
        // Assert
        XCTAssertTrue(result)
        let contains = await service.contains(testHash)
        XCTAssertTrue(contains)
    }
    
    // MARK: - Tests for Hash Deletion
    
    func testDelete_ExistingHash_DeletesSuccessfully() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.populateWithHashes([testHash])
        
        // Act
        let result = await service.delete(testHash)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .deleteItem), 1)
        
        // Verify hash was deleted
        let contains = await service.contains(testHash)
        XCTAssertFalse(contains)
    }
    
    func testDelete_NonExistentHash_ReturnsSuccess() async {
        // Arrange
        let testHash = "TestHash123"
        
        // Act
        let result = await service.delete(testHash)
        
        // Assert
        XCTAssertTrue(result, "DynamoDB treats deleting non-existent items as success")
    }
    
    func testDelete_WithServerError_ReturnsFalse() async {
        // Arrange
        let testHash = "TestHash123"
        mockClient.populateWithHashes([testHash])
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.internalServerError.rawValue,
            userInfo: nil
        ))
        
        // Act
        let result = await service.delete(testHash)
        
        // Assert
        XCTAssertFalse(result)
    }
    
    // MARK: - Tests for Request Format
    
    func testContains_RequestFormat() async {
        // Arrange
        let testHash = "TestHash123"
        
        // Act
        _ = await service.contains(testHash)
        
        // Assert
        XCTAssertEqual(mockClient.getOperationCount(type: .getItem), 1)
        let operation = mockClient.getOperationLog().first { $0.type == .getItem }
        XCTAssertNotNil(operation)
        XCTAssertEqual(operation?.key, testHash)
        XCTAssertEqual(operation?.tableName, testTableName)
    }
    
    func testStore_RequestFormat() async {
        // Arrange
        let testHash = "TestHash123"
        
        // Act
        _ = await service.store(testHash)
        
        // Assert
        XCTAssertEqual(mockClient.getOperationCount(type: .putItem), 1)
        let operation = mockClient.getOperationLog().first { $0.type == .putItem }
        XCTAssertNotNil(operation)
        XCTAssertEqual(operation?.key, testHash)
        XCTAssertEqual(operation?.tableName, testTableName)
    }
    
    // MARK: - Performance and Edge Cases
    
    func testConcurrentAccess() async {
        // Arrange
        let testHashes = (1...10).map { _ in generateRandomHash() }
        
        // Act - perform operations concurrently
        await withTaskGroup(of: Bool.self) { group in
            for hash in testHashes {
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
            
            // Assert - all operations should succeed
            XCTAssertEqual(results.count, testHashes.count)
            XCTAssertTrue(results.allSatisfy { $0 })
        }
    }
    
    func testWithLongHash() async {
        // Arrange - create a very long hash string
        let longHash = String(repeating: "A", count: 1000)
        
        // Act
        let storeResult = await service.store(longHash)
        let containsResult = await service.contains(longHash)
        let deleteResult = await service.delete(longHash)
        
        // Assert
        XCTAssertTrue(storeResult)
        XCTAssertTrue(containsResult)
        XCTAssertTrue(deleteResult)
    }
}

// MARK: - Test Helper Classes

/// A testable subclass that allows us to inject the mock client
class TestableGlobalSignatureService: GlobalSignatureService {
    private let customClient: AWSDynamoDB
    
    init(mockClient: AWSDynamoDB) {
        self.customClient = mockClient
        super.init()
        
        // Override 'client' property using Objective-C runtime
        let clientIvar = class_getInstanceVariable(GlobalSignatureService.self, "_client")
        if let clientIvar = clientIvar {
            object_setIvar(self, clientIvar, mockClient)
        }
    }
}
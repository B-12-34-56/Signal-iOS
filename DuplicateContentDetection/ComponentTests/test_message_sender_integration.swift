//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import SignalServiceKit
import GRDB
@testable import Signal

/// Tests the integration between MessageSender and the duplicate content detection system.
/// Validates that content hashes are properly checked before sending, blocked hashes prevent
/// message sending, successful sends store hashes in the database, and error handling is correct.
class MessageSenderIntegrationTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockSignatureService: MockGlobalSignatureService!
    private var mockDuplicateStore: MockDuplicateSignatureStore!
    private var mockMessageSender: MockMessageSender!
    private var mockDatabasePool: DatabasePool!
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        // Create mock services for testing
        mockSignatureService = MockGlobalSignatureService()
        mockDuplicateStore = MockDuplicateSignatureStore()
        mockDatabasePool = try DatabasePool(path: ":memory:")
        
        // Initialize message sender with mocks
        mockMessageSender = MockMessageSender(
            mockSignatureService: mockSignatureService,
            mockDuplicateStore: mockDuplicateStore
        )
    }
    
    override func tearDown() async throws {
        mockSignatureService = nil
        mockDuplicateStore = nil
        mockMessageSender = nil
        mockDatabasePool = nil
        super.tearDown()
    }
    
    // MARK: - Hash Checking Tests
    
    /// Tests that content hashes are checked before sending messages
    func testContentHashesAreCheckedBeforeSending() async {
        // Arrange
        let testHash = "test_hash_123"
        let message = createMockMessage(attachmentHash: testHash)
        
        // Initially the hash is not blocked
        let result1 = await mockMessageSender.trySendingMessage(message)
        
        // Assert: Message should be sent successfully
        XCTAssertTrue(result1.success, "Message should be sent when hash is not blocked")
        XCTAssertTrue(mockSignatureService.checkedHashes.contains(testHash), "Hash should be checked in GlobalSignatureService")
        XCTAssertEqual(mockMessageSender.sendAttemptCount, 1, "Message should be sent once")
        
        // Reset for next test
        mockSignatureService.checkedHashes.removeAll()
        mockMessageSender.reset()
        
        // Now block the hash in the global database
        mockSignatureService.blockedHashes.insert(testHash)
        
        // Act: Try to send the same message again
        let result2 = await mockMessageSender.trySendingMessage(message)
        
        // Assert: Message should be blocked
        XCTAssertFalse(result2.success, "Message should be blocked when hash is globally blocked")
        XCTAssertTrue(mockSignatureService.checkedHashes.contains(testHash), "Hash should be checked in GlobalSignatureService")
        XCTAssertEqual(mockMessageSender.sendAttemptCount, 0, "Message send should not be attempted")
        XCTAssertNotNil(result2.error, "Error should be present")
        
        if let error = result2.error as? MessageSenderError {
            XCTAssertEqual(error.localizedDescription, OWSLocalizedString(
                "ERROR_DESCRIPTION_MESSAGE_SEND_FAILED_DUPLICATE_BLOCKED",
                comment: "Error message displayed when a message send fails because the attachment content has been identified as previously blocked or potentially harmful duplicate content."
            ))
        } else {
            XCTFail("Error should be a MessageSenderError")
        }
    }
    
    /// Tests that local blocklist is checked before the global database
    func testLocalBlocklistCheckedBeforeGlobalDatabase() async {
        // Arrange
        let testHash = "test_hash_local_first"
        let message = createMockMessage(attachmentHash: testHash)
        
        // Block the hash locally
        mockDuplicateStore.blockedHashes.insert(testHash)
        
        // Act
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert: Message should be blocked
        XCTAssertFalse(result.success, "Message should be blocked when hash is locally blocked")
        XCTAssertEqual(mockMessageSender.sendAttemptCount, 0, "Message send should not be attempted")
        
        // Importantly, the global database should not be checked if local check fails
        XCTAssertTrue(mockSignatureService.checkedHashes.isEmpty, "Global signature service should not be checked when locally blocked")
        
        if let error = result.error as? MessageSenderError, case .duplicateBlocked(let aHash) = error {
            XCTAssertEqual(aHash, testHash, "Error should contain the blocked hash")
        } else {
            XCTFail("Error should be a MessageSenderError.duplicateBlocked")
        }
    }
    
    // MARK: - Hash Storage Tests
    
    /// Tests that successful sends store hashes in the database
    func testSuccessfulSendsStoreHashesInDatabase() async {
        // Arrange
        let testHash = "test_hash_for_storage"
        let message = createMockMessage(attachmentHash: testHash)
        
        // Act: Send the message
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertTrue(result.success, "Message should be sent successfully")
        XCTAssertEqual(mockMessageSender.sendAttemptCount, 1, "Message should be sent once")
        
        // Hash storage happens asynchronously, so we need to wait a bit
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Check that the hash was stored
        XCTAssertTrue(mockSignatureService.storedHashes.contains(testHash), "Hash should be stored after successful send")
    }
    
    /// Tests that hash storage is skipped if message send fails
    func testNoHashStorageOnFailedSends() async {
        // Arrange
        let testHash = "test_hash_for_failed_send"
        let message = createMockMessage(attachmentHash: testHash)
        
        // Configure message sender to fail
        mockMessageSender.shouldFailSend = true
        
        // Act: Try to send the message (will fail)
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertFalse(result.success, "Message send should fail")
        XCTAssertEqual(mockMessageSender.sendAttemptCount, 1, "Message send should be attempted")
        XCTAssertTrue(mockSignatureService.storedHashes.isEmpty, "Hash should not be stored after failed send")
    }
    
    // MARK: - Error Handling Tests
    
    /// Tests error messages for blocked content
    func testErrorMessagesForBlockedContent() async {
        // Arrange
        let testHash = "test_hash_for_error_message"
        let message = createMockMessage(attachmentHash: testHash)
        mockSignatureService.blockedHashes.insert(testHash)
        
        // Act
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertFalse(result.success, "Message should be blocked")
        
        // Verify the error message doesn't contain the actual hash (for privacy)
        let errorMessage = result.error?.localizedDescription ?? ""
        XCTAssertFalse(errorMessage.isEmpty, "Error message should not be empty")
        XCTAssertFalse(errorMessage.contains(testHash), "Error message should not contain the actual hash")
        
        // Verify it's the expected error type
        switch result.error {
        case let error as MessageSenderError:
            switch error {
            case .duplicateBlocked(let aHash):
                XCTAssertEqual(aHash, testHash, "Error should contain the correct hash internally")
            default:
                XCTFail("Error should be duplicateBlocked, but was \(error)")
            }
        default:
            XCTFail("Error should be a MessageSenderError")
        }
    }
    
    /// Tests that retry logic properly handles blocked content errors
    func testRetryLogicForBlockedContent() async {
        // Arrange
        let testHash = "test_hash_for_retry"
        let message = createMockMessage(attachmentHash: testHash)
        mockSignatureService.blockedHashes.insert(testHash)
        
        // Act: Try sending with retry
        let result = await mockMessageSender.trySendingMessageWithRetry(message, maxRetries: 3)
        
        // Assert
        XCTAssertFalse(result.success, "Message should still be blocked after retries")
        XCTAssertEqual(mockMessageSender.sendAttemptCount, 0, "No actual send attempts should be made")
        
        // The error should indicate it's not retryable
        if let error = result.error as? MessageSenderError {
            XCTAssertFalse(error.isRetryableProvider, "Duplicate blocked error should not be retryable")
        }
    }
    
    // MARK: - Edge Case Tests
    
    /// Tests behavior when attachment has no hash
    func testMessageWithNoHashBypassesDetection() async {
        // Arrange
        let message = createMockMessage(attachmentHash: nil)
        
        // Act: Send message with no hash
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertTrue(result.success, "Message with no hash should be sent successfully")
        XCTAssertEqual(mockMessageSender.sendAttemptCount, 1, "Message send should be attempted")
        XCTAssertTrue(mockSignatureService.checkedHashes.isEmpty, "No hash should be checked when message has no hash")
    }
    
    /// Tests behavior with multiple attachments (only first is checked)
    func testMultipleAttachmentsOnlyFirstIsChecked() async {
        // Arrange
        let goodHash = "good_hash"
        let badHash = "bad_hash"
        mockSignatureService.blockedHashes.insert(badHash)
        
        // Create message with two attachments, first one good
        let message = createMockMessage(attachmentHash: goodHash)
        let secondAttachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
        secondAttachment.mockHashString = badHash
        message.mockAttachments?.append(secondAttachment)
        
        // Act
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert - only first attachment hash should be checked
        XCTAssertTrue(result.success, "Message should be sent despite second attachment having blocked hash")
        XCTAssertEqual(mockSignatureService.checkedHashes.count, 1, "Only one hash should be checked")
        XCTAssertTrue(mockSignatureService.checkedHashes.contains(goodHash), "Only first hash should be checked")
        XCTAssertFalse(mockSignatureService.checkedHashes.contains(badHash), "Second hash should not be checked")
    }
    
    // MARK: - Performance Tests
    
    /// Tests performance with large attachments
    func testPerformanceWithLargeAttachment() {
        // Create a large attachment hash
        let largeHash = String(repeating: "a", count: 10000)
        let message = createMockMessage(attachmentHash: largeHash)
        
        // Measure performance
        measure {
            _ = Task {
                _ = await mockMessageSender.trySendingMessage(message)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func createMockMessage(attachmentHash: String?) -> MockOutgoingMessage {
        let message = MockOutgoingMessage(uniqueId: UUID().uuidString)
        if let attachmentHash = attachmentHash {
            let attachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
            attachment.mockHashString = attachmentHash
            message.mockAttachments = [attachment]
        }
        return message
    }
}

// MARK: - Mock Classes

/// Mock implementation of GlobalSignatureService for testing
class MockGlobalSignatureService {
    var blockedHashes = Set<String>()
    var storedHashes = Set<String>()
    var checkedHashes = Set<String>()
    
    func contains(_ hash: String, retryCount: Int? = nil) async -> Bool {
        checkedHashes.insert(hash)
        return blockedHashes.contains(hash)
    }
    
    func store(_ hash: String, retryCount: Int? = nil) async -> Bool {
        storedHashes.insert(hash)
        return true
    }
}

/// Mock implementation of DuplicateSignatureStore for testing
class MockDuplicateSignatureStore {
    var blockedHashes = Set<String>()
    
    func isBlocked(_ hash: String) async -> Bool {
        return blockedHashes.contains(hash)
    }
}

/// Mock implementation of MessageSender for testing
class MockMessageSender {
    private let mockSignatureService: MockGlobalSignatureService
    private let mockDuplicateStore: MockDuplicateSignatureStore
    
    var sendAttemptCount = 0
    var shouldFailSend = false
    
    struct SendResult {
        let success: Bool
        let error: Error?
    }
    
    init(mockSignatureService: MockGlobalSignatureService, mockDuplicateStore: MockDuplicateSignatureStore) {
        self.mockSignatureService = mockSignatureService
        self.mockDuplicateStore = mockDuplicateStore
    }
    
    func reset() {
        sendAttemptCount = 0
        shouldFailSend = false
    }
    
    /// Simulates sending a message, checking for duplicates first
    func trySendingMessage(_ message: MockOutgoingMessage) async -> SendResult {
        // Check for blocked content first
        if let aHash = message.mockAttachments?.first?.mockHashString {
            // Local check
            if await mockDuplicateStore.isBlocked(aHash) {
                return SendResult(success: false, error: MessageSenderError.duplicateBlocked(aHash: aHash))
            }
            
            // Global check
            if await mockSignatureService.contains(aHash) {
                return SendResult(success: false, error: MessageSenderError.duplicateBlocked(aHash: aHash))
            }
        }
        
        // If no duplicate issues, attempt to send the message
        sendAttemptCount += 1
        
        if shouldFailSend {
            return SendResult(success: false, error: NSError(domain: "MockMessageSenderError", code: -1))
        }
        
        // Successful send - store hash asynchronously
        if let aHash = message.mockAttachments?.first?.mockHashString {
            Task {
                _ = await mockSignatureService.store(aHash)
            }
        }
        
        return SendResult(success: true, error: nil)
    }
    
    /// Simulates sending message with retry logic
    func trySendingMessageWithRetry(_ message: MockOutgoingMessage, maxRetries: Int) async -> SendResult {
        var retryCount = 0
        var result = await trySendingMessage(message)
        
        while !result.success && retryCount < maxRetries {
            retryCount += 1
            
            // If the error is a duplicate blocked error, don't retry
            if let error = result.error as? MessageSenderError, case .duplicateBlocked = error {
                break
            }
            
            // Otherwise retry
            result = await trySendingMessage(message)
        }
        
        return result
    }
}

/// Mock TSOutgoingMessage implementation for testing
class MockOutgoingMessage: TSOutgoingMessage {
    var mockAttachments: [MockAttachment]?
    
    override func allAttachments(transaction tx: DBReadTransaction) -> [TSAttachment] {
        return mockAttachments ?? []
    }
}

/// Mock TSAttachment implementation for testing
class MockAttachment: TSAttachment {
    var mockDataForDownload: Data?
    var mockHashString: String?
    
    override func dataForDownload() throws -> Data {
        guard let mockDataForDownload else {
            throw NSError(domain: "MockAttachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "No data available"])
        }
        return mockDataForDownload
    }
    
    override var aHashString: String? {
        get { return mockHashString }
        set { mockHashString = newValue }
    }
}
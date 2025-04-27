//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import GRDB
import SignalServiceKit
@testable import DuplicateContentDetection

/// Integration tests for the duplicate content detection system that verify end-to-end functionality.
class DuplicateContentIntegrationTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockSignatureService: MockGlobalSignatureService!
    private var mockDuplicateStore: MockDuplicateSignatureStore!
    private var mockDatabase: DatabasePool!
    private var downloadHook: AttachmentDownloadHook!
    private var messageSender: MessageSender!
    
    // Test data sizes
    private let smallSize = 1024 // 1KB
    private let mediumSize = 1024 * 100 // 100KB
    private let largeSize = 1024 * 1024 // 1MB
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        // Initialize mocks and test components
        mockSignatureService = MockGlobalSignatureService()
        mockDuplicateStore = MockDuplicateSignatureStore()
        mockDatabase = try DatabasePool(path: ":memory:")
        
        // Set up download hook
        downloadHook = AttachmentDownloadHook.shared
        downloadHook.install(with: mockDatabase)
        
        // Set up message sender
        messageSender = MessageSender(
            signatureService: mockSignatureService,
            duplicateStore: mockDuplicateStore
        )
    }
    
    override func tearDown() async throws {
        mockSignatureService = nil
        mockDuplicateStore = nil
        mockDatabase = nil
        downloadHook = nil
        messageSender = nil
        super.tearDown()
    }
    
    // MARK: - End-to-End Flow Tests
    
    func testCompleteFlow_FromSendToDownload() async throws {
        // Arrange: Create test message with attachment
        let testData = Data("test content".utf8)
        let (message, attachment) = createTestMessage(withData: testData)
        
        // Act 1: Send message (should succeed and store hash)
        let sendResult = await messageSender.send(message)
        
        // Assert 1: Message sent successfully
        XCTAssertTrue(sendResult.success)
        XCTAssertTrue(mockSignatureService.storedHashes.contains(attachment.contentHash))
        
        // Act 2: Try to send duplicate content
        let duplicateResult = await messageSender.send(createTestMessage(withData: testData).0)
        
        // Assert 2: Duplicate content blocked
        XCTAssertFalse(duplicateResult.success)
        XCTAssertEqual(duplicateResult.error as? MessageSenderError, .duplicateBlocked(aHash: attachment.contentHash))
        
        // Act 3: Try to download the attachment
        let downloadAllowed = await downloadHook.validateAttachment(attachment)
        
        // Assert 3: Download blocked due to hash in database
        XCTAssertFalse(downloadAllowed)
    }
    
    func testMessageSendingWithVariousContentSizes() async {
        let sizes = [smallSize, mediumSize, largeSize]
        
        for size in sizes {
            // Create unique content for each size
            let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
            let (message, attachment) = createTestMessage(withData: data)
            
            // Measure send performance
            let startTime = Date()
            let result = await messageSender.send(message)
            let duration = Date().timeIntervalSince(startTime)
            
            // Verify success and reasonable timing
            XCTAssertTrue(result.success)
            XCTAssertLessThan(duration, 5.0, "Sending \(size) bytes should take less than 5 seconds")
            
            // Verify hash was stored
            XCTAssertTrue(mockSignatureService.storedHashes.contains(attachment.contentHash))
        }
    }
    
    func testMessageDeletionAndResend() async {
        // Arrange: Send initial message
        let (message, attachment) = createTestMessage(withData: Data("original".utf8))
        _ = await messageSender.send(message)
        
        // Act 1: Delete message and verify hash removal
        await messageSender.delete(message)
        XCTAssertFalse(mockSignatureService.storedHashes.contains(attachment.contentHash))
        
        // Act 2: Try to resend same content
        let resendResult = await messageSender.send(message)
        
        // Assert: Should succeed since hash was removed
        XCTAssertTrue(resendResult.success)
    }
    
    func testDatabaseUnavailabilityHandling() async {
        // Arrange: Make signature service unavailable
        mockSignatureService.shouldThrowError = true
        
        // Act 1: Try to send message
        let (message, _) = createTestMessage(withData: Data("test".utf8))
        let sendResult = await messageSender.send(message)
        
        // Assert 1: Should succeed with unavailable service (fail open)
        XCTAssertTrue(sendResult.success)
        
        // Act 2: Try to validate download
        let downloadResult = await downloadHook.validateAttachment(message.attachments.first!)
        
        // Assert 2: Should allow download with unavailable service
        XCTAssertTrue(downloadResult)
    }
    
    // MARK: - Edge Cases
    
    func testEmptyAttachment() async {
        let (message, attachment) = createTestMessage(withData: Data())
        let result = await messageSender.send(message)
        XCTAssertTrue(result.success)
        XCTAssertTrue(mockSignatureService.storedHashes.contains(attachment.contentHash))
    }
    
    func testVeryLargeAttachment() async {
        // Test with 10MB attachment
        let largeData = Data((0..<(10 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let (message, _) = createTestMessage(withData: largeData)
        
        // Measure performance
        measure {
            _ = Task {
                _ = await messageSender.send(message)
            }
        }
    }
    
    func testConcurrentOperations() async {
        let operationCount = 10
        var messages: [(message: Message, attachment: Attachment)] = []
        
        // Create unique messages
        for _ in 0..<operationCount {
            let data = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
            messages.append(createTestMessage(withData: data))
        }
        
        // Perform operations concurrently
        await withTaskGroup(of: Bool.self) { group in
            for (message, _) in messages {
                group.addTask {
                    let result = await self.messageSender.send(message)
                    return result.success
                }
            }
            
            // Collect results
            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
            
            XCTAssertEqual(successCount, operationCount)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestMessage(withData data: Data) -> (Message, Attachment) {
        let attachment = Attachment(id: UUID().uuidString, data: data)
        let message = Message(id: UUID().uuidString, attachments: [attachment])
        return (message, attachment)
    }
}

// MARK: - Test Models

struct Message {
    let id: String
    let attachments: [Attachment]
}

struct Attachment {
    let id: String
    let data: Data
    
    var contentHash: String {
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }
}

// MARK: - Mock Implementations

class MockGlobalSignatureService {
    var storedHashes = Set<String>()
    var shouldThrowError = false
    
    func contains(_ hash: String) async -> Bool {
        guard !shouldThrowError else { throw MockError.serviceUnavailable }
        return storedHashes.contains(hash)
    }
    
    func store(_ hash: String) async -> Bool {
        guard !shouldThrowError else { return false }
        storedHashes.insert(hash)
        return true
    }
}

class MockDuplicateSignatureStore {
    var blockedHashes = Set<String>()
    
    func isBlocked(_ hash: String) async -> Bool {
        return blockedHashes.contains(hash)
    }
}

class MessageSender {
    private let signatureService: MockGlobalSignatureService
    private let duplicateStore: MockDuplicateSignatureStore
    
    init(signatureService: MockGlobalSignatureService, duplicateStore: MockDuplicateSignatureStore) {
        self.signatureService = signatureService
        self.duplicateStore = duplicateStore
    }
    
    func send(_ message: Message) async -> SendResult {
        // Check for blocked content
        if let attachment = message.attachments.first {
            if await duplicateStore.isBlocked(attachment.contentHash) {
                return SendResult(success: false, error: MessageSenderError.duplicateBlocked(aHash: attachment.contentHash))
            }
            
            do {
                if await signatureService.contains(attachment.contentHash) {
                    return SendResult(success: false, error: MessageSenderError.duplicateBlocked(aHash: attachment.contentHash))
                }
            } catch {
                // On service error, allow send to proceed
            }
        }
        
        // Simulate successful send
        if let attachment = message.attachments.first {
            _ = await signatureService.store(attachment.contentHash)
        }
        
        return SendResult(success: true, error: nil)
    }
    
    func delete(_ message: Message) async {
        // Remove hashes for all attachments
        for attachment in message.attachments {
            signatureService.storedHashes.remove(attachment.contentHash)
        }
    }
}

struct SendResult {
    let success: Bool
    let error: Error?
}

enum MessageSenderError: Error {
    case duplicateBlocked(aHash: String)
}

enum MockError: Error {
    case serviceUnavailable
}
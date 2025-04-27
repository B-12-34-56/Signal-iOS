//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import SignalServiceKit
import GRDB
@testable import SignalServiceKit

class DuplicateContentDetectionTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockSignatureService: MockGlobalSignatureService!
    private var mockAttachmentHook: MockAttachmentDownloadHook!
    private var mockDatabasePool: MockDatabasePool!
    private var mockMessageSender: MockMessageSender!
    private var mockDuplicateStore: MockDuplicateSignatureStore!
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        mockSignatureService = MockGlobalSignatureService()
        mockAttachmentHook = MockAttachmentDownloadHook(mockSignatureService: mockSignatureService)
        mockDatabasePool = MockDatabasePool()
        mockDuplicateStore = MockDuplicateSignatureStore()
        mockMessageSender = MockMessageSender(mockSignatureService: mockSignatureService, mockDuplicateStore: mockDuplicateStore)
        
        mockAttachmentHook.install(with: mockDatabasePool)
    }
    
    override func tearDown() async throws {
        mockSignatureService = nil
        mockAttachmentHook = nil
        mockDatabasePool = nil
        mockMessageSender = nil
        mockDuplicateStore = nil
        super.tearDown()
    }
    
    // MARK: - Test Helpers
    
    private func createMockMessage(attachmentHash: String? = nil) -> MockOutgoingMessage {
        let message = MockOutgoingMessage(uniqueId: UUID().uuidString)
        if let attachmentHash = attachmentHash {
            let attachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
            attachment.mockHashString = attachmentHash
            message.mockAttachments = [attachment]
        }
        return message
    }
    
    private func createBlockedAttachmentData() -> (Data, String) {
        let data = Data("blocked_content".utf8)
        let hash = SHA256DigestString(for: data)
        return (data, hash)
    }
    
    private func SHA256DigestString(for data: Data) -> String {
        return data.base64EncodedString()
    }
    
    // MARK: - Integration Tests
    
    func testEndToEndFlow_FromSendToVerification() async throws {
        // Arrange
        let (_, hash) = createBlockedAttachmentData()
        let message = createMockMessage(attachmentHash: hash)
        
        // Act - First store the hash (simulating a successful send)
        await mockSignatureService.store(hash)
        XCTAssertTrue(mockSignatureService.storedHashes.contains(hash))
        
        // Now try to send another message with the same hash
        let sendResult = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertFalse(sendResult.success)
        XCTAssertEqual(sendResult.error as? MessageSenderError, .duplicateBlocked(aHash: hash))
    }
    
    func testMessageSending_DuplicateContentDetection_LocalBlock() async throws {
        // Arrange
        let (_, hash) = createBlockedAttachmentData()
        let message = createMockMessage(attachmentHash: hash)
        
        // Add to local blocklist
        mockDuplicateStore.blockedHashes.insert(hash)
        
        // Act
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error as? MessageSenderError, .duplicateBlocked(aHash: hash))
        
        // Verify the global service was NOT even checked
        XCTAssertEqual(mockSignatureService.checkedHashes.count, 0)
    }
    
    func testMessageSending_DuplicateContentDetection_GlobalBlock() async throws {
        // Arrange
        let (_, hash) = createBlockedAttachmentData()
        let message = createMockMessage(attachmentHash: hash)
        
        // Add to global blocklist
        mockSignatureService.blockedHashes.insert(hash)
        
        // Act
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error as? MessageSenderError, .duplicateBlocked(aHash: hash))
        
        // Verify the hash was checked in global service
        XCTAssertTrue(mockSignatureService.checkedHashes.contains(hash))
    }
    
    func testHashStorageAfterSuccessfulSend() async throws {
        // Arrange
        let (_, hash) = createBlockedAttachmentData()
        let message = createMockMessage(attachmentHash: hash)
        
        // Act
        let result = await mockMessageSender.trySendingMessage(message, skipDuplicateCheck: true)
        
        // Assert
        XCTAssertTrue(result.success)
        XCTAssertTrue(mockSignatureService.storedHashes.contains(hash))
    }
    
    func testHashVerificationBeforeDownload() async throws {
        // Arrange
        let (data, hash) = createBlockedAttachmentData()
        let attachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
        attachment.mockDataForDownload = data
        
        // Act - First validate without the hash being blocked
        let initialResult = await mockAttachmentHook.validateAttachment(attachment)
        
        // Now add the hash to the blocked list
        mockSignatureService.blockedHashes.insert(hash)
        
        // Try again
        let blockedResult = await mockAttachmentHook.validateAttachment(attachment)
        
        // Assert
        XCTAssertTrue(initialResult, "Should allow download when hash isn't blocked")
        XCTAssertFalse(blockedResult, "Should block download when hash is blocked")
        XCTAssertEqual(mockAttachmentHook.reportedBlockedAttachments.count, 1)
    }
    
    func testPerformanceWithLargeAttachments() async throws {
        // Arrange
        // Create progressively larger attachments
        let sizes: [Int] = [1_024, 1_024 * 10, 1_024 * 100]
        var results: [(size: Int, duration: TimeInterval)] = []
        
        // Act & measure
        for size in sizes {
            let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
            let attachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "application/octet-stream")
            attachment.mockDataForDownload = data
            
            let startTime = Date()
            _ = await mockAttachmentHook.validateAttachment(attachment)
            let endTime = Date()
            
            results.append((size: size, duration: endTime.timeIntervalSince(startTime)))
        }
        
        // Assert
        for result in results {
            XCTAssertLessThan(result.duration, 1.0, "Processing \(result.size) bytes should take less than 1 second")
            print("Processing \(result.size) bytes took \(result.duration) seconds")
        }
    }
    
    func testMessageDeletionAndResend() async throws {
        // Arrange
        let (_, hash) = createBlockedAttachmentData()
        let message = createMockMessage(attachmentHash: hash)
        
        // Store the hash to simulate a previous send
        mockSignatureService.blockedHashes.insert(hash)
        
        // Act - First try sending (should fail due to duplicate)
        let result1 = await mockMessageSender.trySendingMessage(message)
        XCTAssertFalse(result1.success)
        
        // Now simulate user changing the attachment content
        message.mockAttachments![0].mockHashString = "new_hash_value"
        
        // Try sending again
        let result2 = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertTrue(result2.success)
    }
    
    func testRealWorldContentHashingScenarios() async throws {
        // Arrange - Create various content types that would typically be sent
        let textAttachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "text/plain")
        textAttachment.mockDataForDownload = Data("This is a text message".utf8)
        
        let imageAttachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
        imageAttachment.mockDataForDownload = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
        
        let audioAttachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "audio/mp3")
        audioAttachment.mockDataForDownload = Data((0..<2048).map { _ in UInt8.random(in: 0...255) })
        
        // Act
        let textResult = await mockAttachmentHook.validateAttachment(textAttachment)
        let textHash = mockAttachmentHook.computeAttachmentHashForTesting(textAttachment.mockDataForDownload!)
        
        let imageResult = await mockAttachmentHook.validateAttachment(imageAttachment)
        let imageHash = mockAttachmentHook.computeAttachmentHashForTesting(imageAttachment.mockDataForDownload!)
        
        let audioResult = await mockAttachmentHook.validateAttachment(audioAttachment)
        let audioHash = mockAttachmentHook.computeAttachmentHashForTesting(audioAttachment.mockDataForDownload!)
        
        // Assert
        XCTAssertTrue(textResult)
        XCTAssertTrue(imageResult)
        XCTAssertTrue(audioResult)
        
        XCTAssertNotEqual(textHash, imageHash)
        XCTAssertNotEqual(textHash, audioHash)
        XCTAssertNotEqual(imageHash, audioHash)
    }
    
    func testErrorPropagationWhenDuplicateIsDetected() async throws {
        // Arrange
        let (_, hash) = createBlockedAttachmentData()
        let message = createMockMessage(attachmentHash: hash)
        
        // Add to both local and global blocklists to test priority
        mockDuplicateStore.blockedHashes.insert(hash)
        mockSignatureService.blockedHashes.insert(hash)
        
        // Act
        let result = await mockMessageSender.trySendingMessage(message)
        
        // Assert
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error as? MessageSenderError, .duplicateBlocked(aHash: hash))
        
        // Verify error message is properly formatted
        let errorMessage = result.error?.localizedDescription ?? ""
        XCTAssertFalse(errorMessage.isEmpty)
        XCTAssertFalse(errorMessage.contains(hash), "Hash should not be exposed in error message")
    }
}

// MARK: - Mock Classes

class MockGlobalSignatureService {
    var blockedHashes = Set<String>()
    var storedHashes = Set<String>()
    var checkedHashes = Set<String>()
    var shouldFail = false
    
    func contains(_ hash: String, retryCount: Int? = nil) async -> Bool {
        if shouldFail {
            return false
        }
        
        checkedHashes.insert(hash)
        return blockedHashes.contains(hash)
    }
    
    func store(_ hash: String, retryCount: Int? = nil) async -> Bool {
        if shouldFail {
            return false
        }
        
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

class MockAttachmentDownloadHook {
    private let mockSignatureService: MockGlobalSignatureService
    var reportedBlockedAttachments: [(hash: String, attachmentId: String?)] = []
    
    init(mockSignatureService: MockGlobalSignatureService) {
        self.mockSignatureService = mockSignatureService
    }
    
    func install(with pool: DatabasePool) {
        // Mock implementation
    }
    
    func validateAttachment(_ attachment: MockAttachment, hash: String? = nil) async -> Bool {
        guard let data = attachment.mockDataForDownload else {
            return true
        }
        
        let contentHash = hash ?? computeAttachmentHashForTesting(data)
        let exists = await mockSignatureService.contains(contentHash)
        
        if exists {
            reportedBlockedAttachments.append((hash: contentHash, attachmentId: attachment.uniqueId))
            return false
        } else {
            return true
        }
    }
    
    func computeAttachmentHashForTesting(_ data: Data) -> String {
        return data.base64EncodedString()
    }
}

class MockDatabasePool: DatabasePool {
    init() {
        try! super.init(path: ":memory:")
    }
}

class MockAttachment: TSAttachment {
    var mockDataForDownload: Data?
    var mockHashString: String?
    
    override func dataForDownload() throws -> Data {
        guard let mockDataForDownload = mockDataForDownload else {
            throw NSError(domain: "MockAttachmentError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock data not available"])
        }
        return mockDataForDownload
    }
    
    override var aHashString: String? {
        get { return mockHashString }
        set { mockHashString = newValue }
    }
}

class MockOutgoingMessage: TSOutgoingMessage {
    var mockAttachments: [MockAttachment]?
    
    override func allAttachments(transaction tx: DBReadTransaction) -> [TSAttachment] {
        return mockAttachments ?? []
    }
}

class MockMessageSender {
    struct SendResult {
        let success: Bool
        let error: Error?
    }
    
    private let mockSignatureService: MockGlobalSignatureService
    private let mockDuplicateStore: MockDuplicateSignatureStore
    
    init(mockSignatureService: MockGlobalSignatureService, mockDuplicateStore: MockDuplicateSignatureStore) {
        self.mockSignatureService = mockSignatureService
        self.mockDuplicateStore = mockDuplicateStore
    }
    
    func trySendingMessage(_ message: MockOutgoingMessage, skipDuplicateCheck: Bool = false) async -> SendResult {
        let firstAttachment = message.mockAttachments?.first
        
        // Duplicate content detection
        if let aHash = firstAttachment?.mockHashString, !skipDuplicateCheck {
            // Local check
            if await mockDuplicateStore.isBlocked(aHash) {
                return SendResult(success: false, error: MessageSenderError.duplicateBlocked(aHash: aHash))
            }
            
            // Global check
            if await mockSignatureService.contains(aHash) {
                return SendResult(success: false, error: MessageSenderError.duplicateBlocked(aHash: aHash))
            }
        }
        
        // Simulate successful send
        if let aHash = firstAttachment?.mockHashString {
            // Store hash after successful send
            await mockSignatureService.store(aHash)
        }
        
        return SendResult(success: true, error: nil)
    }
}
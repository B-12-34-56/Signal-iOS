//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import GRDB
import SignalServiceKit
@testable import Signal

class AttachmentDownloadRetryRunnerTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockDatabasePool: MockDatabasePool!
    private var mockDownloadManager: MockAttachmentDownloadManager!
    private var mockDownloadStore: MockAttachmentDownloadStore!
    private var mockSignatureService: MockGlobalSignatureService!
    private var retryRunner: AttachmentDownloadRetryRunner!
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        mockDatabasePool = MockDatabasePool()
        mockDownloadManager = MockAttachmentDownloadManager()
        mockDownloadStore = MockAttachmentDownloadStore()
        mockSignatureService = MockGlobalSignatureService()
        
        retryRunner = AttachmentDownloadRetryRunner(
            attachmentDownloadManager: mockDownloadManager,
            attachmentDownloadStore: mockDownloadStore,
            db: SDSDatabaseStorageMock(grdbStorage: .init(dbPool: mockDatabasePool))
        )
    }
    
    override func tearDown() async throws {
        mockDatabasePool = nil
        mockDownloadManager = nil
        mockDownloadStore = nil
        mockSignatureService = nil
        retryRunner = nil
        super.tearDown()
    }
    
    // MARK: - Test Cases
    
    func testPeriodicRetryMechanism() async throws {
        // Arrange
        let attachmentId = "test_attachment_1"
        let hash = "blocked_hash_1"
        let record = createMockRecord(attachmentId: attachmentId, hash: hash)
        mockDownloadStore.mockRetryableDownloads = [record]
        mockSignatureService.blockedHashes.insert(hash)
        
        // Act
        retryRunner.beginObserving()
        
        // Let the runner process
        try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(NSEC_PER_SEC)))
        
        // Assert
        XCTAssertEqual(mockDownloadStore.retryAttemptUpdates.count, 1, "Should have attempted retry")
        XCTAssertEqual(mockDownloadStore.retryAttemptUpdates[0].newAttemptCount, 1, "Attempt count should increment")
    }
    
    func testRetryStateManagement() async throws {
        // Arrange
        let record1 = createMockRecord(attachmentId: "test_1", hash: "hash_1", retryAttempt: 0)
        let record2 = createMockRecord(attachmentId: "test_2", hash: "hash_2", retryAttempt: 2)
        mockDownloadStore.mockRetryableDownloads = [record1, record2]
        
        // Act
        retryRunner.beginObserving()
        try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(NSEC_PER_SEC)))
        
        // Assert
        XCTAssertEqual(mockDownloadStore.retryAttemptUpdates.count, 2, "Both records should be processed")
        XCTAssertEqual(mockDownloadStore.retryAttemptUpdates[0].newAttemptCount, 1)
        XCTAssertEqual(mockDownloadStore.retryAttemptUpdates[1].newAttemptCount, 3)
    }
    
    func testSignatureServiceIntegration() async throws {
        // Arrange
        let hash = "test_hash"
        let record = createMockRecord(hash: hash)
        mockDownloadStore.mockRetryableDownloads = [record]
        
        // Test case 1: Hash still blocked
        mockSignatureService.blockedHashes.insert(hash)
        retryRunner.beginObserving()
        try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(NSEC_PER_SEC)))
        XCTAssertEqual(mockDownloadStore.retryAttemptUpdates.count, 1, "Should schedule retry when blocked")
        
        // Test case 2: Hash no longer blocked
        mockSignatureService.blockedHashes.remove(hash)
        mockDownloadStore.retryAttemptUpdates = [] // Reset tracking
        retryRunner.beginObserving()
        try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(NSEC_PER_SEC)))
        XCTAssertEqual(mockDownloadStore.downloadableMarks.count, 1, "Should mark as downloadable when unblocked")
    }
    
    func testCancellationAndResumption() async throws {
        // Arrange
        let record = createMockRecord()
        mockDownloadStore.mockRetryableDownloads = [record]
        
        // Act - Start observing
        retryRunner.beginObserving()
        try? await Task.sleep(nanoseconds: UInt64(0.2 * Double(NSEC_PER_SEC)))
        
        // Simulate app entering background/foreground
        NotificationCenter.default.post(name: .OWSApplicationWillEnterForeground, object: nil)
        
        // Assert
        XCTAssertTrue(mockDownloadManager.downloadingBegan, "Download manager should be triggered on resume")
    }
    
    func testRetryScheduling() async throws {
        // Arrange
        let records = [
            createMockRecord(retryAttempt: 0),
            createMockRecord(retryAttempt: 1),
            createMockRecord(retryAttempt: 2)
        ]
        mockDownloadStore.mockRetryableDownloads = records
        
        // Act
        retryRunner.beginObserving()
        try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(NSEC_PER_SEC)))
        
        // Assert
        let delays = mockDownloadStore.retryAttemptUpdates.map { $0.newTimestamp - Date().ows_millisecondsSince1970 }
        for i in 1..<delays.count {
            XCTAssertGreaterThan(delays[i], delays[i-1], "Later retries should have longer delays")
        }
    }
    
    func testAttachmentDeletion() async throws {
        // Arrange
        let record = createMockRecord()
        mockDownloadStore.mockRetryableDownloads = [record]
        
        // Act
        retryRunner.beginObserving()
        try? await Task.sleep(nanoseconds: UInt64(0.2 * Double(NSEC_PER_SEC)))
        
        // Simulate deletion by removing from store
        mockDownloadStore.mockRetryableDownloads = []
        try? await Task.sleep(nanoseconds: UInt64(0.2 * Double(NSEC_PER_SEC)))
        
        // Assert
        XCTAssertEqual(mockDownloadStore.retryAttemptUpdates.count, 1, "Should process record before deletion")
        XCTAssertEqual(mockDownloadStore.lastNextRetryTimestamp, nil, "Should find no next retry after deletion")
    }
    
    // MARK: - Helper Methods
    
    private func createMockRecord(
        attachmentId: String = "test_attachment",
        hash: String = "test_hash",
        retryAttempt: Int = 0
    ) -> QueuedAttachmentDownloadRecord {
        QueuedAttachmentDownloadRecord(
            id: attachmentId,
            attachmentId: Int64(1),
            attachmentPointerId: attachmentId,
            priority: 1,
            sourceType: .restoreMessage,
            downloadKey: nil,
            aHash: hash,
            minRetryTimestamp: Date().ows_millisecondsSince1970,
            retryAttempt: retryAttempt
        )
    }
}

// MARK: - Mock Classes

class MockAttachmentDownloadManager: AttachmentDownloadManager {
    var downloadingBegan = false
    
    func beginDownloadingIfNecessary() {
        downloadingBegan = true
    }
    
    // Implement other required protocol methods
    func enqueueDownloadOfAttachment(pointer: TSAttachmentPointer, message: TSMessage, transaction: SDSAnyWriteTransaction) {}
    func enqueueDownloadOfAttachmentsForMessage(_ message: TSMessage, transaction: SDSAnyWriteTransaction) {}
    func downloadMessage(_ message: TSMessage, transaction: SDSAnyWriteTransaction) async throws -> Bool { return true }
    func downloadAttachment(_ attachment: TSAttachmentPointer, transaction: SDSAnyWriteTransaction) async throws -> URL { return URL(fileURLWithPath: "") }
    func downloadTransientAttachment(_ pointer: TSAttachmentPointer, transaction: SDSAnyWriteTransaction?) async throws -> URL { return URL(fileURLWithPath: "") }
}

class MockAttachmentDownloadStore: AttachmentDownloadStore {
    var mockRetryableDownloads: [QueuedAttachmentDownloadRecord] = []
    var retryAttemptUpdates: [(id: String, newTimestamp: Int64, newAttemptCount: Int)] = []
    var downloadableMarks: [String] = []
    var lastNextRetryTimestamp: Int64?
    
    func fetchRetryableDownloads(tx: Database, beforeOrAt timestamp: Int64) throws -> [QueuedAttachmentDownloadRecord] {
        return mockRetryableDownloads
    }
    
    func updateRetryAttempt(id: String, newTimestamp: Int64, newAttemptCount: Int, tx: Database) throws {
        retryAttemptUpdates.append((id: id, newTimestamp: newTimestamp, newAttemptCount: newAttemptCount))
    }
    
    func markAsDownloadable(id: String, tx: Database) throws {
        downloadableMarks.append(id)
    }
    
    func nextRetryTimestamp(tx: Database) throws -> Int64? {
        lastNextRetryTimestamp = mockRetryableDownloads.first?.minRetryTimestamp
        return lastNextRetryTimestamp
    }
    
    // Implement other required protocol methods
    func enqueuedDownload(withAttachmentId attachmentId: Int64, sourceType: QueuedAttachmentDownloadRecord.SourceType, tx: Database) throws -> QueuedAttachmentDownloadRecord? { return nil }
    func enqueueDownloadOfAttachment(attachmentId: Int64, messageId: String, messageUniqueId: String?, attachmentPointer: TSAttachmentPointer, downloadBehavior: TSAttachmentDownloadBehavior, source: QueuedAttachmentDownloadRecord.SourceType, tx: Database) throws {}
    func removeAttachmentFromQueue(attachmentId: Int64, source: QueuedAttachmentDownloadRecord.SourceType, tx: Database) throws {}
}

class SDSDatabaseStorageMock: SDSDatabaseStorage {
    init(grdbStorage: GRDBDatabaseStorageAdapter) {
        super.init()
        self.value = .grdb(grdbStorage)
    }
}

class MockGlobalSignatureService {
    var blockedHashes = Set<String>()
    
    func contains(_ hash: String) async -> Bool {
        return blockedHashes.contains(hash)
    }
}

class MockDatabasePool: DatabasePool {
    init() {
        try! super.init(path: ":memory:")
    }
}
//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import GRDB
import SignalServiceKit
@testable import Signal

class AttachmentDownloadHookTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockSignatureService: MockGlobalSignatureService!
    private var downloadHook: TestableAttachmentDownloadHook!
    private var mockDatabasePool: MockDatabasePool!
    private var reportedBlockedAttachments: [(String, String?)] = []
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        mockSignatureService = MockGlobalSignatureService()
        mockDatabasePool = MockDatabasePool()
        
        downloadHook = TestableAttachmentDownloadHook(
            mockSignatureService: mockSignatureService,
            reportCallback: { hash, attachmentId in
                self.reportedBlockedAttachments.append((hash, attachmentId))
            }
        )
        
        downloadHook.install(with: mockDatabasePool)
        reportedBlockedAttachments = []
    }
    
    override func tearDown() async throws {
        mockSignatureService = nil
        downloadHook = nil
        mockDatabasePool = nil
        reportedBlockedAttachments = []
        super.tearDown()
    }
    
    // MARK: - Test Helper Methods
    
    private func createMockAttachment(id: String = UUID().uuidString, data: Data? = nil) -> MockAttachment {
        let attachment = MockAttachment(uniqueId: id, contentType: "image/jpeg")
        attachment.mockDataForDownload = data ?? Data(count: 1024) // 1KB of random data
        return attachment
    }
    
    private func createBlockedAttachment() -> (MockAttachment, String) {
        let data = Data("blocked_content".utf8)
        let attachment = createMockAttachment(data: data)
        let hash = downloadHook.computeAttachmentHashForTesting(data)
        mockSignatureService.blockedHashes.insert(hash)
        return (attachment, hash)
    }
    
    // MARK: - Tests for Attachment Validation
    
    func testValidateAttachment_AllowedHash_ReturnsTrue() async {
        // Arrange
        let attachment = createMockAttachment()
        
        // Act
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert
        XCTAssertTrue(result, "Attachment with non-blocked hash should be allowed")
        XCTAssertTrue(mockSignatureService.checkedHashes.count == 1, "Hash should be checked against service")
    }
    
    func testValidateAttachment_BlockedHash_ReturnsFalse() async {
        // Arrange
        let (blockedAttachment, hash) = createBlockedAttachment()
        
        // Act
        let result = await downloadHook.validateAttachment(blockedAttachment)
        
        // Assert
        XCTAssertFalse(result, "Attachment with blocked hash should not be allowed")
        XCTAssertTrue(mockSignatureService.checkedHashes.contains(hash), "Blocked hash should be checked")
        XCTAssertEqual(reportedBlockedAttachments.count, 1, "Blocked attachment should be reported")
        XCTAssertEqual(reportedBlockedAttachments[0].0, hash, "Reported hash should match")
        XCTAssertEqual(reportedBlockedAttachments[0].1, blockedAttachment.uniqueId, "Reported attachment ID should match")
    }
    
    func testValidateAttachment_WithExistingHash_SkipsComputation() async {
        // Arrange
        let attachment = createMockAttachment()
        let providedHash = "provided_hash_value"
        mockSignatureService.blockedHashes.insert(providedHash)
        
        // Act
        let result = await downloadHook.validateAttachment(attachment, hash: providedHash)
        
        // Assert
        XCTAssertFalse(result, "Attachment with provided blocked hash should not be allowed")
        XCTAssertTrue(mockSignatureService.checkedHashes.contains(providedHash), "Provided hash should be checked")
        XCTAssertEqual(reportedBlockedAttachments.count, 1, "Blocked attachment should be reported")
    }
    
    func testValidateAttachment_NoDatabasePool_ReturnsTrue() async {
        // Arrange
        let hookWithoutDatabase = TestableAttachmentDownloadHook(
            mockSignatureService: mockSignatureService,
            reportCallback: { _, _ in }
        )
        let (blockedAttachment, _) = createBlockedAttachment()
        
        // Act - no database installed
        let result = await hookWithoutDatabase.validateAttachment(blockedAttachment)
        
        // Assert
        XCTAssertTrue(result, "Attachment validation without database pool should return true")
    }
    
    func testValidateAttachment_AttachmentWithoutData_ReturnsTrue() async {
        // Arrange
        let attachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
        attachment.mockDataForDownload = nil // Simulate error when loading data
        
        // Act
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert
        XCTAssertTrue(result, "Attachment without data should be allowed")
        XCTAssertTrue(mockSignatureService.checkedHashes.isEmpty, "No hash should be checked")
    }
    
    func testValidateAttachment_ServiceError_ReturnsTrue() async {
        // Arrange
        let attachment = createMockAttachment()
        mockSignatureService.shouldFail = true
        
        // Act
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert
        XCTAssertTrue(result, "Attachment should be allowed when service fails")
    }
    
    // MARK: - Tests for Hash Computation
    
    func testComputeAttachmentHash_ConsistentResults() async {
        // Arrange
        let testData = Data("test data for hashing".utf8)
        
        // Act
        let hash1 = downloadHook.computeAttachmentHashForTesting(testData)
        let hash2 = downloadHook.computeAttachmentHashForTesting(testData)
        
        // Assert
        XCTAssertEqual(hash1, hash2, "Hash computation should be consistent for the same data")
    }
    
    func testComputeAttachmentHash_DifferentForDifferentData() async {
        // Arrange
        let testData1 = Data("test data 1".utf8)
        let testData2 = Data("test data 2".utf8)
        
        // Act
        let hash1 = downloadHook.computeAttachmentHashForTesting(testData1)
        let hash2 = downloadHook.computeAttachmentHashForTesting(testData2)
        
        // Assert
        XCTAssertNotEqual(hash1, hash2, "Different data should produce different hashes")
    }
    
    // MARK: - Tests for Utility Methods
    
    func testGenerateTestingHash_UniquenessAndFormat() {
        // Act
        let hash1 = downloadHook.generateTestingHash()
        let hash2 = downloadHook.generateTestingHash()
        
        // Assert
        XCTAssertNotEqual(hash1, hash2, "Generated testing hashes should be unique")
        
        // Base64 strings should be a multiple of 4 characters
        XCTAssertTrue(hash1.count % 4 == 0, "Hash should be valid base64")
        XCTAssertTrue(hash2.count % 4 == 0, "Hash should be valid base64")
    }
    
    func testAddKnownBadHash_AddsToDatabase() async {
        // Arrange
        let testHash = "test_bad_hash"
        
        // Act
        downloadHook.addKnownBadHashForTesting(testHash)
        
        // Give time for the task to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Assert
        XCTAssertEqual(mockSignatureService.storedHashes.count, 1, "Hash should be stored in the database")
        XCTAssertEqual(mockSignatureService.storedHashes.first, testHash, "Stored hash should match")
    }
}

// MARK: - Test Helper Classes

class MockGlobalSignatureService {
    var blockedHashes = Set<String>()
    var checkedHashes = Set<String>()
    var storedHashes = Set<String>()
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

class MockDatabasePool: DatabasePool {
    init() {
        // Create an in-memory database for testing
        try! super.init(path: ":memory:")
    }
}

class TestableAttachmentDownloadHook: AttachmentDownloadHook {
    private let mockSignatureService: MockGlobalSignatureService
    private let reportCallback: (String, String?) -> Void
    
    init(mockSignatureService: MockGlobalSignatureService, reportCallback: @escaping (String, String?) -> Void) {
        self.mockSignatureService = mockSignatureService
        self.reportCallback = reportCallback
        super.init()
    }
    
    override func validateHash(_ hash: String, attachmentId: String?) async -> Bool {
        let exists = await mockSignatureService.contains(hash)
        if exists {
            Task {
                try await reportBlockedAttachment(hash: hash, attachmentId: attachmentId)
            }
            return false
        } else {
            return true
        }
    }
    
    override func reportBlockedAttachment(hash: String, attachmentId: String?) async throws {
        reportCallback(hash, attachmentId)
    }
    
    func computeAttachmentHashForTesting(_ data: Data) -> String {
        return super.computeAttachmentHash(data)
    }
}

class MockAttachment: TSAttachment {
    var mockDataForDownload: Data?
    
    override func dataForDownload() throws -> Data {
        guard let mockDataForDownload = mockDataForDownload else {
            throw NSError(domain: "MockAttachmentError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock data not available"])
        }
        return mockDataForDownload
    }
}
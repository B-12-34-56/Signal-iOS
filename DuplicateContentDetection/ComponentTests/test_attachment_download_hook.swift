//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import GRDB
import CryptoKit
import SignalServiceKit
@testable import Signal

/// This test validates the functionality of the AttachmentDownloadHook
/// which is responsible for preventing downloads of blocked content.
class AttachmentDownloadHookTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockSignatureService: MockGlobalSignatureService!
    private var downloadHook: TestableAttachmentDownloadHook!
    private var mockDatabasePool: DatabasePool!
    private var reportedBlockedAttachments: [(hash: String, attachmentId: String?)] = []
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        // Create mock services and database pool
        mockSignatureService = MockGlobalSignatureService()
        mockDatabasePool = try DatabasePool(path: ":memory:")
        
        // Create hook with custom reporting callback to track blocked attachments
        downloadHook = TestableAttachmentDownloadHook(
            mockSignatureService: mockSignatureService,
            reportCallback: { hash, attachmentId in
                self.reportedBlockedAttachments.append((hash: hash, attachmentId: attachmentId))
            }
        )
        
        // Install the hook with our mock database
        downloadHook.install(with: mockDatabasePool)
        reportedBlockedAttachments.removeAll()
    }
    
    override func tearDown() async throws {
        mockSignatureService = nil
        downloadHook = nil
        mockDatabasePool = nil
        reportedBlockedAttachments.removeAll()
        super.tearDown()
    }
    
    // MARK: - Basic Validation Tests
    
    /// Tests that an attachment with non-blocked content is allowed
    func testValidateAttachment_AllowedAttachment() async {
        // Arrange: Create an attachment with content not in the blocked list
        let attachment = createMockAttachment()
        
        // Act: Validate the attachment
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert: Should be allowed since hash is not blocked
        XCTAssertTrue(result, "Attachment should be allowed when its hash is not blocked")
        XCTAssertEqual(reportedBlockedAttachments.count, 0, "No blocked attachments should be reported")
    }
    
    /// Tests that an attachment with blocked content is prevented from downloading
    func testValidateAttachment_BlockedAttachment() async {
        // Arrange: Create a blocked attachment
        let (attachment, hash) = createBlockedAttachment()
        
        // Act: Validate the attachment
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert: Should be blocked and reported
        XCTAssertFalse(result, "Attachment should be blocked when its hash is in the blocked list")
        XCTAssertEqual(reportedBlockedAttachments.count, 1, "Blocked attachment should be reported")
        XCTAssertEqual(reportedBlockedAttachments[0].hash, hash, "Reported hash should match")
        XCTAssertEqual(reportedBlockedAttachments[0].attachmentId, attachment.uniqueId, "Reported attachment ID should match")
    }
    
    // MARK: - Edge Cases and Error Handling Tests
    
    /// Tests behavior when database pool is not configured
    func testValidateAttachment_NoDatabasePool() async {
        // Arrange: Create hook without database pool
        let hookWithoutDatabase = TestableAttachmentDownloadHook(
            mockSignatureService: mockSignatureService, 
            reportCallback: { _, _ in }
        )
        let attachment = createMockAttachment()
        
        // Act: Validate attachment without installing database pool
        let result = await hookWithoutDatabase.validateAttachment(attachment)
        
        // Assert: Should default to allowing the attachment
        XCTAssertTrue(result, "Attachment should be allowed when database pool is not configured")
    }
    
    /// Tests behavior when attachment data cannot be accessed
    func testValidateAttachment_NoAttachmentData() async {
        // Arrange: Create attachment that will fail to provide data
        let attachment = createMockAttachment(data: nil)
        attachment.shouldFailDataFetch = true
        
        // Act: Validate attachment
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert: Should default to allowing the attachment when data can't be accessed
        XCTAssertTrue(result, "Attachment should be allowed when data cannot be accessed")
    }
    
    /// Tests behavior when signature service encounters an error
    func testValidateAttachment_SignatureServiceError() async {
        // Arrange: Configure service to throw error
        let attachment = createMockAttachment()
        mockSignatureService.shouldThrowError = true
        
        // Act: Validate attachment
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert: Should default to allowing the attachment on service error
        XCTAssertTrue(result, "Attachment should be allowed when signature service fails")
    }
    
    // MARK: - Pre-provided Hash Tests
    
    /// Tests using a pre-provided hash instead of computing it
    func testValidateAttachment_WithProvidedHash() async {
        // Arrange: Setup a blocked hash
        let providedHash = "provided_test_hash"
        mockSignatureService.blockedHashes.insert(providedHash)
        let attachment = createMockAttachment()
        
        // Act: Validate using provided hash
        let result = await downloadHook.validateAttachment(attachment, hash: providedHash)
        
        // Assert: Should be blocked based on provided hash
        XCTAssertFalse(result, "Attachment should be blocked when provided hash is in block list")
        XCTAssertEqual(reportedBlockedAttachments.count, 1, "Blocked attachment should be reported")
        XCTAssertEqual(reportedBlockedAttachments[0].hash, providedHash, "Reported hash should match provided hash")
    }
    
    // MARK: - Test Utility Methods
    
    /// Tests adding known bad hashes to the database
    func testAddKnownBadHashForTesting() async {
        // Arrange: Create a test hash
        let testHash = "test_bad_hash_123"
        
        // Act: Add the hash to the blocked list
        downloadHook.addKnownBadHashForTesting(testHash)
        
        // Give time for the async task to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Assert: Hash should be stored in the service
        XCTAssertTrue(mockSignatureService.storedHashes.contains(testHash), "Hash should be added to storage")
        
        // Create an attachment with matching hash
        let attachment = createMockAttachment()
        attachment.mockHashString = testHash
        
        // Validate that it's now blocked
        let result = await downloadHook.validateAttachment(attachment)
        XCTAssertFalse(result, "Attachment should be blocked after adding hash")
    }
    
    /// Tests hash generation for testing
    func testGenerateTestingHash() {
        // Act: Generate two hashes
        let hash1 = downloadHook.generateTestingHash()
        let hash2 = downloadHook.generateTestingHash()
        
        // Assert: Hashes should be valid and unique
        XCTAssertNotEqual(hash1, hash2, "Generated hashes should be unique")
        XCTAssertFalse(hash1.isEmpty, "Generated hash should not be empty")
        XCTAssertTrue(hash1.count > 16, "Hash should be a proper length for SHA-256")
    }
    
    // MARK: - Hash Computation Tests
    
    /// Tests that hash computation is consistent
    func testHashComputation_Consistency() {
        // Arrange: Create same data twice
        let testData1 = Data("test content".utf8)
        let testData2 = Data("test content".utf8)
        
        // Act: Compute hashes
        let hash1 = downloadHook.computeHashForTesting(testData1)
        let hash2 = downloadHook.computeHashForTesting(testData2)
        
        // Assert: Hashes should match for identical content
        XCTAssertEqual(hash1, hash2, "Hash computation should be consistent for identical content")
    }
    
    /// Tests that different data produces different hashes
    func testHashComputation_Uniqueness() {
        // Arrange: Create different data samples
        let testData1 = Data("content one".utf8)
        let testData2 = Data("content two".utf8)
        
        // Act: Compute hashes
        let hash1 = downloadHook.computeHashForTesting(testData1)
        let hash2 = downloadHook.computeHashForTesting(testData2)
        
        // Assert: Hashes should be different for different content
        XCTAssertNotEqual(hash1, hash2, "Different content should produce different hashes")
    }
    
    // MARK: - Integration with GlobalSignatureService Tests
    
    /// Tests full integration flow with GlobalSignatureService
    func testIntegrationWithSignatureService() async {
        // Arrange: Setup a hash in the service
        let testHash = "integration_test_hash"
        mockSignatureService.blockedHashes.insert(testHash)
        
        // Create an attachment with this hash
        let attachment = createMockAttachment()
        attachment.mockHashString = testHash
        
        // Act: First check - should be blocked
        let result1 = await downloadHook.validateAttachment(attachment)
        XCTAssertFalse(result1, "Attachment should be blocked when hash is in service")
        
        // Now remove the hash from blocked list
        mockSignatureService.blockedHashes.remove(testHash)
        
        // Act: Second check - should now be allowed
        let result2 = await downloadHook.validateAttachment(attachment)
        XCTAssertTrue(result2, "Attachment should be allowed after hash is removed from service")
        
        // Verify service was called for both checks
        XCTAssertEqual(mockSignatureService.hashCheckCount, 2, "Signature service should be checked twice")
    }
    
    // MARK: - Performance Tests
    
    /// Tests performance with large attachments
    func testPerformanceWithLargeAttachment() {
        // Create a large data attachment (1MB)
        let largeData = Data(count: 1024 * 1024) // 1MB of random data
        
        // Measure performance of hash computation
        measure {
            _ = downloadHook.computeHashForTesting(largeData)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createMockAttachment(id: String = UUID().uuidString, data: Data? = nil) -> MockAttachment {
        let attachment = MockAttachment(uniqueId: id, contentType: "image/jpeg")
        attachment.mockDataForDownload = data ?? Data("test attachment content".utf8)
        return attachment
    }
    
    private func createBlockedAttachment() -> (MockAttachment, String) {
        let data = Data("blocked content".utf8)
        let attachment = createMockAttachment(data: data)
        let hash = downloadHook.computeHashForTesting(data)
        mockSignatureService.blockedHashes.insert(hash)
        return (attachment, hash)
    }
}

// MARK: - Mock Classes

/// A mock implementation of GlobalSignatureService for testing
class MockGlobalSignatureService {
    var blockedHashes = Set<String>()
    var storedHashes = Set<String>()
    var hashCheckCount = 0
    var shouldThrowError = false
    
    func contains(_ hash: String, retryCount: Int? = nil) async throws -> Bool {
        if shouldThrowError {
            throw NSError(domain: "MockSignatureService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Simulated service failure"])
        }
        
        hashCheckCount += 1
        return blockedHashes.contains(hash)
    }
    
    func store(_ hash: String, retryCount: Int? = nil) async -> Bool {
        storedHashes.insert(hash)
        blockedHashes.insert(hash) // Also mark as blocked for testing
        return true
    }
}

/// A testable subclass of AttachmentDownloadHook with exposed methods for testing
class TestableAttachmentDownloadHook: AttachmentDownloadHook {
    private let mockSignatureService: MockGlobalSignatureService
    private let reportCallback: (String, String?) -> Void
    
    init(mockSignatureService: MockGlobalSignatureService, reportCallback: @escaping (String, String?) -> Void) {
        self.mockSignatureService = mockSignatureService
        self.reportCallback = reportCallback
        super.init()
    }
    
    override func validateHash(_ hash: String, attachmentId: String?) async -> Bool {
        do {
            let exists = try await mockSignatureService.contains(hash)
            if exists {
                Task {
                    try await reportBlockedAttachment(hash: hash, attachmentId: attachmentId)
                }
                return false
            } else {
                return true
            }
        } catch {
            return true // Default allow on error
        }
    }
    
    override func reportBlockedAttachment(hash: String, attachmentId: String?) async throws {
        reportCallback(hash, attachmentId)
    }
    
    override func addKnownBadHashForTesting(_ hash: String) {
        Task {
            await mockSignatureService.store(hash)
        }
    }
    
    func computeHashForTesting(_ data: Data) -> String {
        return super.computeAttachmentHash(data)
    }
}

/// A mock TSAttachment implementation for testing
class MockAttachment: TSAttachment {
    var mockDataForDownload: Data?
    var mockHashString: String?
    var shouldFailDataFetch = false
    
    override func dataForDownload() throws -> Data {
        if shouldFailDataFetch {
            throw NSError(domain: "MockAttachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated data fetch failure"])
        }
        
        guard let mockDataForDownload = mockDataForDownload else {
            throw NSError(domain: "MockAttachment", code: 2, userInfo: [NSLocalizedDescriptionKey: "No mock data available"])
        }
        
        return mockDataForDownload
    }
    
    override var aHashString: String? {
        get { return mockHashString }
        set { mockHashString = newValue }
    }
}
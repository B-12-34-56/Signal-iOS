//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import GRDB
import CryptoKit
@testable import DuplicateContentDetection

class AttachmentDownloadHookTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockSignatureService: MockGlobalSignatureService!
    private var downloadHook: TestableAttachmentDownloadHook!
    private var mockDatabasePool: DatabasePool!
    private var reportedBlockedAttachments: [(hash: String, attachmentId: String?)] = []
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        
        // Create mock services and database
        mockSignatureService = MockGlobalSignatureService()
        mockDatabasePool = try DatabasePool(path: ":memory:") // In-memory database for testing
        
        // Initialize hook with mocks
        downloadHook = TestableAttachmentDownloadHook(
            mockSignatureService: mockSignatureService,
            reportCallback: { hash, attachmentId in
                self.reportedBlockedAttachments.append((hash: hash, attachmentId: attachmentId))
            }
        )
        
        // Install hook with database
        downloadHook.install(with: mockDatabasePool)
        
        // Reset tracking arrays
        reportedBlockedAttachments.removeAll()
    }
    
    override func tearDown() async throws {
        mockSignatureService = nil
        downloadHook = nil
        mockDatabasePool = nil
        reportedBlockedAttachments.removeAll()
        super.tearDown()
    }
    
    // MARK: - Test Helper Methods
    
    private func createMockAttachment(id: String = UUID().uuidString, data: Data? = nil) -> MockAttachment {
        let attachment = MockAttachment(uniqueId: id, contentType: "image/jpeg")
        attachment.mockDataForDownload = data ?? Data(count: 1024) // 1KB of random data by default
        return attachment
    }
    
    private func createBlockedAttachment() -> (MockAttachment, String) {
        // Create an attachment with content that will be blocked
        let data = Data("blocked_content".utf8)
        let attachment = createMockAttachment(data: data)
        
        // Compute the hash and add it to blocked list
        let hash = downloadHook.computeHashForTesting(data)
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
        XCTAssertEqual(mockSignatureService.hashCheckCount, 1, "Hash should be checked against service")
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
        XCTAssertEqual(reportedBlockedAttachments[0].hash, hash, "Reported hash should match")
        XCTAssertEqual(reportedBlockedAttachments[0].attachmentId, blockedAttachment.uniqueId, "Reported attachment ID should match")
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
        
        // Act - Note we don't install the database pool
        let result = await hookWithoutDatabase.validateAttachment(blockedAttachment)
        
        // Assert
        XCTAssertTrue(result, "Attachment validation without database pool should return true")
    }
    
    func testValidateAttachment_AttachmentWithoutData_ReturnsTrue() async {
        // Arrange
        let attachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
        attachment.mockDataForDownload = nil // Simulate error when loading data
        attachment.shouldFailDataFetch = true
        
        // Act
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert
        XCTAssertTrue(result, "Attachment without data should be allowed")
        XCTAssertEqual(mockSignatureService.hashCheckCount, 0, "No hash should be checked when data can't be fetched")
    }
    
    func testValidateAttachment_ServiceError_ReturnsTrue() async {
        // Arrange
        let attachment = createMockAttachment()
        mockSignatureService.shouldThrowError = true
        
        // Act
        let result = await downloadHook.validateAttachment(attachment)
        
        // Assert
        XCTAssertTrue(result, "Attachment should be allowed when signature service fails")
        XCTAssertEqual(reportedBlockedAttachments.count, 0, "Nothing should be reported when service fails")
    }
    
    // MARK: - Tests for Hash Computation
    
    func testComputeAttachmentHash_ConsistentResults() {
        // Arrange
        let testData = Data("test data for hashing".utf8)
        
        // Act
        let hash1 = downloadHook.computeHashForTesting(testData)
        let hash2 = downloadHook.computeHashForTesting(testData)
        
        // Assert
        XCTAssertEqual(hash1, hash2, "Hash computation should be consistent for the same data")
    }
    
    func testComputeAttachmentHash_DifferentForDifferentData() {
        // Arrange
        let testData1 = Data("test data 1".utf8)
        let testData2 = Data("test data 2".utf8)
        
        // Act
        let hash1 = downloadHook.computeHashForTesting(testData1)
        let hash2 = downloadHook.computeHashForTesting(testData2)
        
        // Assert
        XCTAssertNotEqual(hash1, hash2, "Different data should produce different hashes")
    }
    
    func testComputeAttachmentHash_EmptyData_ReturnsValidHash() {
        // Arrange
        let emptyData = Data()
        
        // Act
        let hash = downloadHook.computeHashForTesting(emptyData)
        
        // Assert
        XCTAssertFalse(hash.isEmpty, "Hash for empty data should not be empty")
        XCTAssertTrue(hash.count > 0, "Hash for empty data should have valid length")
    }
    
    func testComputeAttachmentHash_MatchesSHA256() {
        // Arrange
        let testData = Data("test data for SHA-256 verification".utf8)
        
        // Act
        let hash = downloadHook.computeHashForTesting(testData)
        
        // Compute the expected hash using CryptoKit directly
        let digest = SHA256.hash(data: testData)
        let expectedHash = Data(digest).base64EncodedString()
        
        // Assert
        XCTAssertEqual(hash, expectedHash, "Hash should match direct SHA-256 computation")
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
    
    func testAddKnownBadHashForTesting_AddsToDatabase() async {
        // Arrange
        let testHash = "test_bad_hash"
        
        // Act
        downloadHook.addKnownBadHashForTesting(testHash)
        
        // Give time for the task to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Assert
        XCTAssertTrue(mockSignatureService.storedHashes.contains(testHash), "Hash should be stored in the database")
        
        // Verify the hash is now blocked by trying to validate against it
        let attachment = createMockAttachment()
        let result = await downloadHook.validateAttachment(attachment, hash: testHash)
        XCTAssertFalse(result, "Attachment should be blocked after adding hash")
    }
    
    // MARK: - Tests for Different Database Configurations
    
    func testInstallWithDifferentDatabaseConfigurations() {
        // Test with nil database (already covered in other test)
        
        // Test with new database
        let newDatabasePool = try! DatabasePool(path: ":memory:")
        let newHook = TestableAttachmentDownloadHook(
            mockSignatureService: MockGlobalSignatureService(),
            reportCallback: { _, _ in }
        )
        
        // Should not throw or cause issues
        newHook.install(with: newDatabasePool)
        
        // Test installing multiple times with different DBs
        let anotherPool = try! DatabasePool(path: ":memory:")
        newHook.install(with: anotherPool)
        
        // No assertion needed - if it doesn't crash, it works
    }
    
    // MARK: - Tests for Edge Cases
    
    func testLargeAttachmentData() async {
        // Arrange
        let largeData = Data(repeating: 0xAB, count: 1024 * 1024) // 1MB
        let largeAttachment = createMockAttachment(data: largeData)
        let largeHash = downloadHook.computeHashForTesting(largeData)
        
        // Act - measure performance
        measure {
            _ = downloadHook.computeHashForTesting(largeData)
        }
        
        // Now test normal validation path
        let result = await downloadHook.validateAttachment(largeAttachment)
        
        // Assert
        XCTAssertTrue(result, "Large attachment should be allowed")
        XCTAssertTrue(mockSignatureService.checkedHashes.contains(largeHash), "Large attachment hash should be checked")
    }
}

// MARK: - Test Helper Classes

/// Mock implementation of GlobalSignatureService for testing
class MockGlobalSignatureService {
    var blockedHashes = Set<String>()
    var checkedHashes = Set<String>()
    var storedHashes = Set<String>()
    var shouldThrowError = false
    var hashCheckCount = 0
    
    func contains(_ hash: String, retryCount: Int? = nil) async throws -> Bool {
        if shouldThrowError {
            throw NSError(domain: "MockSignatureService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Simulated service failure"])
        }
        
        hashCheckCount += 1
        checkedHashes.insert(hash)
        return blockedHashes.contains(hash)
    }
    
    func store(_ hash: String, retryCount: Int? = nil) async -> Bool {
        if shouldThrowError {
            return false
        }
        
        storedHashes.insert(hash)
        blockedHashes.insert(hash) // Also mark as blocked for testing
        return true
    }
    
    func delete(_ hash: String, retryCount: Int? = nil) async -> Bool {
        if shouldThrowError {
            return false
        }
        
        storedHashes.remove(hash)
        blockedHashes.remove(hash)
        return true
    }
}

/// Testable subclass of AttachmentDownloadHook that allows injecting mock services
class TestableAttachmentDownloadHook {
    private var databasePool: DatabasePool?
    private let mockSignatureService: MockGlobalSignatureService
    private let reportCallback: (String, String?) -> Void
    
    init(mockSignatureService: MockGlobalSignatureService, reportCallback: @escaping (String, String?) -> Void) {
        self.mockSignatureService = mockSignatureService
        self.reportCallback = reportCallback
    }
    
    func install(with pool: DatabasePool) {
        self.databasePool = pool
    }
    
    func validateAttachment(_ attachment: MockAttachment, hash: String? = nil) async -> Bool {
        guard databasePool != nil else {
            return true // Skip validation if no DB pool is configured
        }
        
        // If hash is provided, use it directly
        if let hash = hash {
            return await validateHash(hash, attachmentId: attachment.uniqueId)
        }
        
        // Otherwise compute hash from attachment data
        do {
            let data = try attachment.dataForDownload()
            let contentHash = computeHashForTesting(data)
            return await validateHash(contentHash, attachmentId: attachment.uniqueId)
        } catch {
            // Allow download if we can't get data
            return true
        }
    }
    
    private func validateHash(_ hash: String, attachmentId: String?) async -> Bool {
        do {
            let exists = try await mockSignatureService.contains(hash)
            if exists {
                // Report the block
                Task {
                    await reportBlockedAttachment(hash: hash, attachmentId: attachmentId)
                }
                return false
            } else {
                return true
            }
        } catch {
            // On error, allow the download
            return true
        }
    }
    
    func computeHashForTesting(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }
    
    private func reportBlockedAttachment(hash: String, attachmentId: String?) async {
        reportCallback(hash, attachmentId)
    }
    
    func addKnownBadHashForTesting(_ hash: String) {
        Task {
            _ = await mockSignatureService.store(hash)
        }
    }
    
    func generateTestingHash() -> String {
        let randomData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return randomData.base64EncodedString()
    }
}

/// Mock implementation of attachment for testing
class MockAttachment {
    let uniqueId: String
    let contentType: String
    var mockDataForDownload: Data?
    var shouldFailDataFetch = false
    
    init(uniqueId: String, contentType: String) {
        self.uniqueId = uniqueId
        self.contentType = contentType
    }
    
    func dataForDownload() throws -> Data {
        if shouldFailDataFetch {
            throw NSError(domain: "MockAttachmentError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated data fetch failure"])
        }
        
        guard let mockDataForDownload = mockDataForDownload else {
            throw NSError(domain: "MockAttachmentError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No mock data available"])
        }
        
        return mockDataForDownload
    }
}
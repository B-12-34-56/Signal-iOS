import XCTest
import Foundation
import GRDB
import CryptoKit
import Logging
import SignalServiceKit
@testable import Signal // To access AttachmentDownloadHook and TSAttachment mocks

/// Test suite for validating the AttachmentDownloadHook integration.
class TestAttachmentDownloadHook: XCTestCase {

    // MARK: - Properties

    private var mockSignatureService: MockGlobalSignatureService!
    private var downloadHook: TestableAttachmentDownloadHook!
    private var mockDatabasePool: DatabasePool!
    private var reportedBlockedAttachments: [(hash: String, attachmentId: String?)] = []
    private var logger: Logger!

    // MARK: - Test Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        logger = Logger(label: "org.signal.tests.TestAttachmentDownloadHook")
        logger.info("Setting up TestAttachmentDownloadHook...")

        // Create mock services and database pool
        mockSignatureService = MockGlobalSignatureService(logger: logger)
        // In-memory DB for hook installation (required but not directly used by mocks)
        mockDatabasePool = try DatabasePool(path: ":memory:")

        // Create hook with custom reporting callback to track blocked attachments
        downloadHook = TestableAttachmentDownloadHook(
            mockSignatureService: mockSignatureService,
            reportCallback: { [weak self] hash, attachmentId in
                self?.logger.info("Reporting blocked attachment: hash=\(hash.prefix(8)), id=\(attachmentId ?? "N/A")")
                self?.reportedBlockedAttachments.append((hash: hash, attachmentId: attachmentId))
            },
            logger: logger
        )

        // Install the hook with our mock database
        downloadHook.install(with: mockDatabasePool)
        reportedBlockedAttachments.removeAll()
        logger.info("Setup complete.")
    }

    override func tearDown() async throws {
        logger.info("Tearing down TestAttachmentDownloadHook...")
        mockSignatureService = nil
        downloadHook = nil
        mockDatabasePool = nil
        reportedBlockedAttachments.removeAll()
        logger = nil
        try await super.tearDown()
        logger.info("Teardown complete.")
    }

    // MARK: - Helper Methods

    /// Logs the start of a test method.
    private func logTestStart(function: String = #function) {
        logger.info("--- Starting test: \(function) ---")
    }

    /// Logs the end of a test method.
    private func logTestEnd(function: String = #function) {
        logger.info("--- Finished test: \(function) ---")
    }

    private func createMockAttachment(id: String = UUID().uuidString, data: Data? = nil) -> MockAttachment {
        let attachment = MockAttachment(uniqueId: id, contentType: "image/jpeg")
        attachment.mockDataForDownload = data ?? Data("test attachment content".utf8)
        return attachment
    }

    private func createBlockedAttachment() -> (MockAttachment, String) {
        let data = Data("blocked content".utf8)
        let attachment = createMockAttachment(data: data)
        let hash = downloadHook.computeHashForTesting(data)
        logger.info("Setting up blocked hash: \(hash.prefix(8))")
        mockSignatureService.blockedHashes.insert(hash)
        return (attachment, hash)
    }

    // MARK: - Test Cases

    /// Tests that hash computation is consistent for the same data and different for different data.
    func testAttachmentHashComputation() {
        logTestStart()
        // Arrange: Create data samples
        let testData1 = Data("test content".utf8)
        let testData2 = Data("test content".utf8) // Identical
        let testData3 = Data("different content".utf8) // Different

        // Act: Compute hashes
        logger.info("Computing hash for data 1...")
        let hash1 = downloadHook.computeHashForTesting(testData1)
        logger.info("Computing hash for data 2...")
        let hash2 = downloadHook.computeHashForTesting(testData2)
        logger.info("Computing hash for data 3...")
        let hash3 = downloadHook.computeHashForTesting(testData3)

        // Assert: Consistency
        logger.info("Hash 1: \(hash1)")
        logger.info("Hash 2: \(hash2)")
        logger.info("Hash 3: \(hash3)")
        XCTAssertEqual(hash1, hash2, "Hash computation should be consistent for identical content.")
        logger.info("Consistency check passed.")

        // Assert: Uniqueness
        XCTAssertNotEqual(hash1, hash3, "Different content should produce different hashes.")
        logger.info("Uniqueness check passed.")
        logTestEnd()
    }

    /// Tests the validation logic for an attachment whose hash is NOT in the signature service.
    func testAttachmentValidation_Allowed() async {
        logTestStart()
        // Arrange: Create an attachment with content not in the blocked list
        let attachment = createMockAttachment()
        let hash = downloadHook.computeHashForTesting(attachment.mockDataForDownload!)
        logger.info("Testing with attachment hash: \(hash.prefix(8)) (should not be blocked)")

        // Act: Validate the attachment
        logger.info("Validating attachment...")
        let result = await downloadHook.validateAttachment(attachment)

        // Assert: Should be allowed since hash is not blocked
        XCTAssertTrue(result, "Attachment should be allowed when its hash is not blocked.")
        XCTAssertEqual(reportedBlockedAttachments.count, 0, "No blocked attachments should be reported.")
        XCTAssertEqual(mockSignatureService.hashCheckCount, 1, "Signature service should have been checked once.")
        logger.info("Validation passed (attachment allowed).")
        logTestEnd()
    }

    /// Tests the validation logic blocks an attachment whose hash IS in the signature service.
    func testAttachmentDownloadBlocking() async {
        logTestStart()
        // Arrange: Create a blocked attachment
        let (attachment, hash) = createBlockedAttachment()
        logger.info("Testing with attachment hash: \(hash.prefix(8)) (should be blocked)")

        // Act: Validate the attachment
        logger.info("Validating attachment...")
        let result = await downloadHook.validateAttachment(attachment)

        // Assert: Should be blocked and reported
        XCTAssertFalse(result, "Attachment should be blocked when its hash is in the blocked list.")
        XCTAssertEqual(reportedBlockedAttachments.count, 1, "Blocked attachment should be reported once.")
        if let reported = reportedBlockedAttachments.first {
            XCTAssertEqual(reported.hash, hash, "Reported hash should match the attachment's hash.")
            XCTAssertEqual(reported.attachmentId, attachment.uniqueId, "Reported attachment ID should match.")
        }
        XCTAssertEqual(mockSignatureService.hashCheckCount, 1, "Signature service should have been checked once.")
        logger.info("Validation passed (attachment blocked).")
        logTestEnd()
    }

    /// Tests behavior when the signature service returns an error during validation.
    func testErrorHandling_SignatureServiceError() async {
        logTestStart()
        // Arrange: Configure service to throw error
        let attachment = createMockAttachment()
        let hash = downloadHook.computeHashForTesting(attachment.mockDataForDownload!)
        logger.info("Testing with signature service error for hash: \(hash.prefix(8))")
        mockSignatureService.shouldThrowError = true

        // Act: Validate attachment
        logger.info("Validating attachment with error simulation...")
        let result = await downloadHook.validateAttachment(attachment)

        // Assert: Should default to allowing the attachment on service error
        XCTAssertTrue(result, "Attachment should be allowed when signature service fails.")
        XCTAssertEqual(reportedBlockedAttachments.count, 0, "No blocked attachments should be reported on error.")
        XCTAssertEqual(mockSignatureService.hashCheckCount, 1, "Signature service should have been called once despite error.")
        logger.info("Error handling passed (attachment allowed on error).")
        logTestEnd()
    }

    /// Tests behavior when attachment data cannot be accessed for hashing.
    func testErrorHandling_NoAttachmentData() async {
        logTestStart()
        // Arrange: Create attachment that will fail to provide data
        let attachment = createMockAttachment(data: nil)
        attachment.shouldFailDataFetch = true
        logger.info("Testing with attachment that fails data fetch.")

        // Act: Validate attachment
        logger.info("Validating attachment with data fetch failure...")
        let result = await downloadHook.validateAttachment(attachment)

        // Assert: Should default to allowing the attachment when data can't be accessed
        XCTAssertTrue(result, "Attachment should be allowed when data cannot be accessed.")
        XCTAssertEqual(reportedBlockedAttachments.count, 0, "No blocked attachments should be reported.")
        XCTAssertEqual(mockSignatureService.hashCheckCount, 0, "Signature service should not be called if hash cannot be computed.")
        logger.info("Error handling passed (attachment allowed when data fetch fails).")
        logTestEnd()
    }
}

// MARK: - Mock Classes (Adapted from existing file)

/// A mock implementation of GlobalSignatureService for testing
private class MockGlobalSignatureService {
    var blockedHashes = Set<String>()
    var storedHashes = Set<String>() // To track stored hashes if needed
    var hashCheckCount = 0
    var shouldThrowError = false
    let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func contains(_ hash: String, retryCount: Int? = nil) async throws -> Bool {
        logger.debug("[MockGSS] Checking hash: \(hash.prefix(8))...")
        hashCheckCount += 1
        if shouldThrowError {
            logger.warning("[MockGSS] Simulating service error for hash: \(hash.prefix(8))")
            throw NSError(domain: "MockSignatureServiceError", code: 503, userInfo: [NSLocalizedDescriptionKey: "Simulated service unavailable"])
        }
        let exists = blockedHashes.contains(hash)
        logger.debug("[MockGSS] Hash \(hash.prefix(8)) exists? \(exists)")
        return exists
    }

    func store(_ hash: String, retryCount: Int? = nil) async -> Bool {
        logger.info("[MockGSS] Storing hash: \(hash.prefix(8))")
        storedHashes.insert(hash)
        // For testing convenience, let's also add it to blockedHashes
        blockedHashes.insert(hash)
        return true
    }

    // Add other methods like delete, batchContains etc. if needed for more complex tests
}

/// A testable subclass of AttachmentDownloadHook using a mock service
private class TestableAttachmentDownloadHook: AttachmentDownloadHook {
    private let mockSignatureService: MockGlobalSignatureService
    private let reportCallback: (String, String?) -> Void
    private let testLogger: Logger // Use a specific logger instance

    init(mockSignatureService: MockGlobalSignatureService, reportCallback: @escaping (String, String?) -> Void, logger: Logger) {
        self.mockSignatureService = mockSignatureService
        self.reportCallback = reportCallback
        self.testLogger = logger
        super.init()
        // Override the logger in the superclass instance if possible, or ensure logging goes via testLogger
         // If super.logger is accessible: self.logger = logger
         // Otherwise, log explicitly using testLogger in overridden methods.
    }

    // Override validateHash to use the mock service
    override func validateHash(_ hash: String, attachmentId: String?) async -> Bool {
        testLogger.debug("Overridden validateHash called with hash: \(hash.prefix(8))")
        do {
            let exists = try await mockSignatureService.contains(hash)
            if exists {
                testLogger.warning("Blocked attachment download (mock): hash \(hash.prefix(8)) found (attachmentId: \(attachmentId ?? "N/A"))")
                // Use Task detached or main actor if report needs specific context, otherwise direct call is fine in tests
                 await reportBlockedAttachment(hash: hash, attachmentId: attachmentId)
                return false
            } else {
                testLogger.info("Allowed attachment download (mock): hash \(hash.prefix(8)) not found.")
                return true
            }
        } catch {
            testLogger.error("Error checking hash in mock service: \(error.localizedDescription). Allowing download.")
            return true // Default allow on error
        }
    }

    // Override reportBlockedAttachment to use the callback
     override func reportBlockedAttachment(hash: String, attachmentId: String?) async {
         testLogger.info("Overridden reportBlockedAttachment called for hash: \(hash.prefix(8))")
         reportCallback(hash, attachmentId)
     }

    // Override addKnownBadHashForTesting to use the mock service
    override func addKnownBadHashForTesting(_ hash: String) {
        testLogger.info("Overridden addKnownBadHashForTesting called for hash: \(hash.prefix(8))")
        Task { // Keep async behavior consistent
            _ = await mockSignatureService.store(hash)
        }
    }

    // Expose hash computation for testing
    func computeHashForTesting(_ data: Data) -> String {
        testLogger.debug("Computing hash for data (\(data.count) bytes)...")
        return super.computeAttachmentHash(data)
    }
}

/// A mock TSAttachment implementation for testing (Ensure this is accessible or redefine)
class MockAttachment: TSAttachment {
    var mockDataForDownload: Data?
    var mockHashString: String? // Allow setting a specific hash for testing
    var shouldFailDataFetch = false

    // Minimal required initializers
     override init(uniqueId: String, contentType: String?) {
         super.init(uniqueId: uniqueId, contentType: contentType)
     }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }


    override func dataForDownload() throws -> Data {
        if shouldFailDataFetch {
            throw NSError(domain: "MockAttachmentError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated data fetch failure"])
        }
        guard let data = mockDataForDownload else {
            throw NSError(domain: "MockAttachmentError", code: 2, userInfo: [NSLocalizedDescriptionKey: "No mock data available"])
        }
        return data
    }

    // Allow overriding the computed hash if needed for specific test scenarios
    override var aHashString: String? {
        get {
            if let forcedHash = mockHashString { return forcedHash }
            // Fallback to computing from data if not forced
             guard let data = try? dataForDownload() else { return nil }
             let digest = SHA256.hash(data: data)
             return Data(digest).base64EncodedString()
        }
        set {
             // Allow setting a mock hash directly if needed by other parts of the system
             // This might conflict with actual data; use with caution or stick to computeHashForTesting
             // For this hook test, relying on computeHashForTesting is sufficient.
             // mockHashString = newValue
        }
    }
}


// MARK: - Standalone Execution Code

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
@main
struct TestAttachmentDownloadHookRunner {
    static func main() async {
        // Check if running via XCTest harness or standalone
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            print("Starting AttachmentDownloadHook Test Runner (Standalone)...")
            let logger = Logger(label: "org.signal.tests.TestAttachmentDownloadHookRunner")

            // Standalone execution doesn't require real AWS setup for these mock-based tests.
            logger.info("Running tests using mock services.")

            // Programmatically find and run tests
            let testSuite = TestAttachmentDownloadHook.defaultTestSuite
            await testSuite.run() // Assumes run() is async or blocks correctly

            print("Test run complete.")
        } else {
            // If run as part of XCTest suite, do nothing here.
            print("Detected XCTest environment. Standalone runner bypassed.")
        }
    }
}
#endif
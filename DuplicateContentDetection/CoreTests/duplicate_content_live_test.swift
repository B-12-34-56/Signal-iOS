//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
import SignalServiceKit // Accessing shared services like GlobalSignatureService
import GRDB            // For database interactions (if needed by hooks)
import CryptoKit       // For hashing
import AWSCore         // Core AWS components
import AWSDynamoDB     // DynamoDB specific components
import Logging         // Logging framework

// Assuming access to the main app's context or relevant components if running within app tests
// If running standalone, mocks or direct service instantiation is needed.
// @testable import Signal // Uncomment if running as part of Signal tests

// --- Configuration ---
// Ensure AWSConfig.swift is correctly configured with Identity Pool ID and region.
// Ensure GlobalSignatureService and AttachmentDownloadHook are accessible.

/// This test script performs a comprehensive live test of the duplicate content detection system.
/// It validates hash storage in DynamoDB, attachment validation, and end-to-end workflows.
/// NOTE: This requires valid AWS credentials configured via AWSConfig and network connectivity.
class DuplicateContentLiveTest {

    // MARK: - Test Configuration

    // Test data sizes to simulate different attachment sizes
    private let testDataSizes = [10, 1024, 1024 * 100] // 10B, 1KB, 100KB
    // Number of runs for repetitive tests
    private let testRuns = 3
    // Delay between certain operations to allow for eventual consistency
    private let testDelay: TimeInterval = 2.0 // Increased delay

    // MARK: - Results Tracking

    private var results = TestResults()
    private let resultsLock = NSLock() // For thread-safe result tracking

    // MARK: - Test Dependencies

    // Assuming these services are accessible; replace with direct instantiation or mocks if needed.
    // In a real test target, these would likely be injected or accessed via a shared environment.
    private let signatureService = GlobalSignatureService.shared
    // private let attachmentDownloadHook = AttachmentDownloadHook.shared // Requires Signal target
    private var databasePool: DatabasePool? // Mock DB pool if needed

    // Logging instance
    private let logger = Logger(label: "org.signal.DuplicateContentLiveTest")

    // MARK: - Entry Point

    /// Main test entry point that orchestrates the test execution.
    func runTests() async {
        printHeader("DUPLICATE CONTENT DETECTION SYSTEM LIVE TEST")

        await setupTestEnvironment()

        // Test 1: AWS Configuration and Connection
        await testAWSConfigurationAndConnection()

        // Test 2: Hash Storage and Retrieval in DynamoDB
        await testHashStorageAndRetrieval()

        // Test 3: Attachment Validation (Simulated Hook)
        await testAttachmentValidation()

        // Test 4: End-to-End Workflow Simulation
        await testEndToEndWorkflow()

        // Generate and print the final report
        generateReport()
    }

    // MARK: - Test Setup

    /// Sets up the test environment, primarily AWS credentials and mock database.
    private func setupTestEnvironment() async {
        logger.info("Setting up test environment...")

        // Initialize AWS credentials using AWSConfig
        // This assumes AWSConfig.swift exists and is configured correctly.
        AWSConfig.setupAWSCredentials()

        // Initialize a mock database pool (in-memory for this test)
        do {
            databasePool = try DatabasePool(path: ":memory:")
            // If AttachmentDownloadHook was directly usable:
            // attachmentDownloadHook.install(with: databasePool!)
            logger.info("✅ Mock database pool created successfully.")
            results.databaseSetupSuccessful = true
        } catch {
            logger.error("❌ Failed to create mock database pool: \(error.localizedDescription)")
            results.databaseSetupSuccessful = false
        }
    }

    // MARK: - Test Cases

    /// Test 1: Validates AWS configuration and basic connection to DynamoDB.
    private func testAWSConfigurationAndConnection() async {
        printHeader("Test 1: AWS Configuration and Connection")
        logger.info("Attempting to validate AWS credentials...")

        let credentialsValid = await AWSConfig.validateAWSCredentials()

        if credentialsValid {
            logger.info("✅ AWS credentials validated successfully.")
            results.awsCredentialsValid = true
            trackResult(.awsConnectionSuccess)
        } else {
            logger.error("❌ AWS credentials validation failed. Subsequent tests might fail.")
            results.awsCredentialsValid = false
            trackResult(.awsConnectionFailure)
        }
    }

    /// Test 2: Tests storing, checking, and deleting hashes in DynamoDB via GlobalSignatureService.
    private func testHashStorageAndRetrieval() async {
        printHeader("Test 2: Hash Storage and Retrieval")

        guard results.awsCredentialsValid else {
            logger.error("⚠️ Skipping hash storage/retrieval test - AWS credentials invalid.")
            return
        }

        let testHashes = (0..<testRuns).map { _ in generateRandomHash() }

        for (index, hash) in testHashes.enumerated() {
            logger.info("--- Hash Test Run \(index + 1)/\(testRuns) ---")
            let hashPrefix = hash.prefix(8)

            // Step 2a: Verify hash doesn't exist initially
            logger.info("Checking if hash \(hashPrefix)... exists (should be false)")
            let existsBefore = await signatureService.contains(hash)
            if !existsBefore {
                logger.info("✅ Hash does not exist initially.")
            } else {
                logger.warning("⚠️ Test hash \(hashPrefix)... already exists. Deleting before proceeding.")
                _ = await signatureService.delete(hash) // Attempt cleanup
            }

            // Step 2b: Store the hash
            logger.info("Attempting to store hash \(hashPrefix)...")
            let storeSuccess = await signatureService.store(hash)
            if storeSuccess {
                logger.info("✅ Hash stored successfully.")
                trackResult(.hashStorageSuccess)
            } else {
                logger.error("❌ Failed to store hash \(hashPrefix)...")
                trackResult(.hashStorageFailure)
                continue // Skip further checks for this hash if store failed
            }

            // Step 2c: Wait for eventual consistency
            logger.info("Waiting \(testDelay)s for eventual consistency...")
            try? await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000))

            // Step 2d: Verify hash now exists
            logger.info("Checking if hash \(hashPrefix)... exists (should be true)")
            let existsAfter = await signatureService.contains(hash)
            if existsAfter {
                logger.info("✅ Hash found after storing.")
                trackResult(.hashRetrievalSuccess)
            } else {
                logger.error("❌ Failed to retrieve hash \(hashPrefix)... after storing.")
                trackResult(.hashRetrievalFailure)
            }

            // Step 2e: Delete the hash
            logger.info("Attempting to delete hash \(hashPrefix)...")
            let deleteSuccess = await signatureService.delete(hash)
            if deleteSuccess {
                logger.info("✅ Hash deleted successfully.")
                trackResult(.hashDeletionSuccess)
            } else {
                logger.error("❌ Failed to delete hash \(hashPrefix)...")
                trackResult(.hashDeletionFailure)
            }

            // Step 2f: Verify hash is deleted
             try? await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000)) // Wait again
             logger.info("Checking if hash \(hashPrefix)... exists (should be false after delete)")
             let existsAfterDelete = await signatureService.contains(hash)
             if !existsAfterDelete {
                 logger.info("✅ Hash confirmed deleted.")
                 trackResult(.hashDeletionVerifySuccess)
             } else {
                 logger.error("❌ Hash still exists after delete \(hashPrefix)...")
                 trackResult(.hashDeletionVerifyFailure)
             }
        }
    }

    /// Test 3: Simulates attachment validation using the core hash checking logic.
    private func testAttachmentValidation() async {
        printHeader("Test 3: Attachment Validation (Simulated Hook)")

        guard results.awsCredentialsValid else {
            logger.error("⚠️ Skipping attachment validation test - AWS credentials invalid.")
            return
        }

        for size in testDataSizes {
            logger.info("--- Attachment Validation Test (Size: \(size) bytes) ---")

            // Step 3a: Test allowed attachment
            logger.info("Testing validation for an 'allowed' attachment...")
            let allowedData = generateRandomData(size: size)
            let allowedHash = computeHash(for: allowedData)
            let validationResultAllowed = await signatureService.contains(allowedHash) // Simulate hook check

            if !validationResultAllowed {
                logger.info("✅ Attachment correctly allowed (hash not found).")
                trackResult(.attachmentValidationSuccess)
            } else {
                logger.error("❌ Attachment incorrectly blocked (hash \(allowedHash.prefix(8))... found unexpectedly).")
                trackResult(.attachmentValidationFailure)
                _ = await signatureService.delete(allowedHash) // Cleanup if found
            }

            // Step 3b: Test blocked attachment
            logger.info("Testing validation for a 'blocked' attachment...")
            let blockedData = generateRandomData(size: size) // Use different data
            let blockedHash = computeHash(for: blockedData)
            logger.info("Storing hash \(blockedHash.prefix(8))... to simulate block.")
            let storeSuccess = await signatureService.store(blockedHash)

            guard storeSuccess else {
                logger.error("❌ Failed to store hash for blocked test. Skipping blocked validation for this size.")
                continue
            }

            try? await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000)) // Wait for consistency

            logger.info("Validating attachment with hash \(blockedHash.prefix(8))... (should be blocked)")
            let validationResultBlocked = await signatureService.contains(blockedHash) // Simulate hook check

            if validationResultBlocked {
                logger.info("✅ Attachment correctly blocked (hash found).")
                trackResult(.blockedAttachmentDetectionSuccess)
            } else {
                logger.error("❌ Attachment incorrectly allowed (hash \(blockedHash.prefix(8))... not found).")
                trackResult(.blockedAttachmentDetectionFailure)
            }

            // Cleanup
            _ = await signatureService.delete(blockedHash)
        }
    }

    /// Test 4: Simulates the full message sending and attachment download flow.
    private func testEndToEndWorkflow() async {
        printHeader("Test 4: End-to-End Workflow Simulation")

        guard results.awsCredentialsValid else {
            logger.error("⚠️ Skipping end-to-end test - AWS credentials invalid.")
            return
        }

        // Step 4a: Simulate sending a message with a new attachment
        logger.info("--- Step 4a: Simulate sending new content ---")
        let originalData = generateRandomData(size: 1024)
        let originalHash = computeHash(for: originalData)
        logger.info("Simulating send for hash \(originalHash.prefix(8))... (should store hash)")
        let sendSuccess = await simulateMessageSend(hash: originalHash) // Just store the hash
        if sendSuccess {
            logger.info("✅ Send simulation successful (hash stored).")
            trackResult(.messageSendSuccess)
        } else {
            logger.error("❌ Send simulation failed (hash not stored).")
            trackResult(.messageSendFailure)
        }

        try? await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000)) // Wait

        // Step 4b: Simulate receiving the same attachment (should be blocked)
        logger.info("--- Step 4b: Simulate receiving duplicate content ---")
        logger.info("Simulating receive for hash \(originalHash.prefix(8))... (should be blocked)")
        let receiveDuplicateAllowed = await simulateMessageReceive(hash: originalHash) // Just check the hash
        if !receiveDuplicateAllowed {
            logger.info("✅ Duplicate content correctly blocked on receive.")
            trackResult(.duplicateDetectionSuccess)
        } else {
            logger.error("❌ Duplicate content *not* blocked on receive.")
            trackResult(.duplicateDetectionFailure)
        }

        // Step 4c: Simulate receiving modified content (should be allowed)
        logger.info("--- Step 4c: Simulate receiving modified content ---")
        var modifiedData = originalData
        if !modifiedData.isEmpty { modifiedData[0] ^= 0xFF } // Modify first byte
        let modifiedHash = computeHash(for: modifiedData)
        logger.info("Simulating receive for modified hash \(modifiedHash.prefix(8))... (should be allowed)")
        let receiveModifiedAllowed = await simulateMessageReceive(hash: modifiedHash) // Check new hash
        if receiveModifiedAllowed {
            logger.info("✅ Modified content correctly allowed on receive.")
            trackResult(.modifiedContentSuccess)
        } else {
            logger.error("❌ Modified content *incorrectly* blocked on receive.")
            trackResult(.modifiedContentFailure)
        }

        // Cleanup
        _ = await signatureService.delete(originalHash)
        _ = await signatureService.delete(modifiedHash) // Delete modified hash if it was stored inadvertently
    }

    // MARK: - Simulation Helpers

    /// Simulates the action taken after a successful message send (storing the hash).
    private func simulateMessageSend(hash: String) async -> Bool {
        // In a real scenario, MessageSender calls store. Here we call it directly.
        return await signatureService.store(hash)
    }

    /// Simulates the validation check during message receive.
    /// Returns true if allowed, false if blocked.
    private func simulateMessageReceive(hash: String) async -> Bool {
        // In a real scenario, AttachmentDownloadHook calls contains. Here we simulate it.
        let isBlocked = await signatureService.contains(hash)
        return !isBlocked // Return true if *allowed* (i.e., not blocked)
    }

    // MARK: - Helper Methods

    /// Generates random data of a specified size.
    private func generateRandomData(size: Int) -> Data {
        guard size > 0 else { return Data() }
        return Data((0..<size).map { _ in UInt8.random(in: 0...255) })
    }

    /// Generates a random Base64 string suitable for testing as a hash.
    private func generateRandomHash() -> String {
        // Generate 32 random bytes and Base64 encode them
        let randomData = generateRandomData(size: 32)
        return randomData.base64EncodedString()
    }

    /// Computes a SHA-256 hash for the provided data and returns it as a Base64 string.
    private func computeHash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }

    /// Thread-safely updates the test results count for a given result type.
    private func trackResult(_ result: TestResultType) {
        resultsLock.lock()
        results.testCounts[result, default: 0] += 1
        resultsLock.unlock()
    }

    /// Prints a formatted header to the log output.
    private func printHeader(_ title: String) {
        let line = String(repeating: "=", count: title.count + 4)
        logger.info("\n\(line)\n  \(title)\n\(line)")
    }

    /// Generates and prints a summary report of the test results.
    private func generateReport() {
        printHeader("TEST RESULTS SUMMARY")

        // Configuration Status
        logger.info("Configuration:")
        logger.info("  - AWS Credentials Validated: \(results.awsCredentialsValid ? "✅ YES" : "❌ NO")")
        logger.info("  - Database Setup Successful: \(results.databaseSetupSuccessful ? "✅ YES" : "❌ NO")")

        // Detailed Test Results
        logger.info("\nDetailed Results:")
        let sortedResults = results.testCounts.sorted { $0.key.rawValue < $1.key.rawValue }
        if sortedResults.isEmpty {
            logger.info("  No tests were executed (likely due to configuration issues).")
        } else {
            for (resultType, count) in sortedResults {
                let statusIcon = resultType.isSuccess ? "✅" : "❌"
                logger.info("  \(statusIcon) \(resultType.description): \(count)")
            }
        }

        // Summary Statistics
        let totalTests = results.testCounts.values.reduce(0, +)
        let successfulTests = results.testCounts.filter { $0.key.isSuccess }.values.reduce(0, +)
        let failedTests = totalTests - successfulTests
        let successRate = totalTests > 0 ? (Double(successfulTests) / Double(totalTests) * 100.0) : 0.0

        logger.info("\nSummary:")
        logger.info("  - Total Test Operations: \(totalTests)")
        logger.info("  - Successful Operations: \(successfulTests)")
        logger.info("  - Failed Operations:     \(failedTests)")
        logger.info("  - Success Rate:          \(String(format: "%.1f%%", successRate))")

        // Overall Result
        // Pass if AWS creds are valid, DB setup worked, and success rate is >= 90%
        let didPass = results.awsCredentialsValid && results.databaseSetupSuccessful && successRate >= 90.0 && totalTests > 0
        let overallResult = didPass ? "✅ PASSED" : "❌ FAILED"
        logger.info("\nOverall Result: \(overallResult)")
        printHeader("END OF TEST")
    }
}

// MARK: - Support Types

/// Structure to hold the results of the test runs.
struct TestResults {
    var awsCredentialsValid = false
    var databaseSetupSuccessful = false
    var testCounts: [TestResultType: Int] = [:]
}

/// Enum defining the different types of test outcomes.
enum TestResultType: Int, CustomStringConvertible {
    // Test 1 Results
    case awsConnectionSuccess
    case awsConnectionFailure

    // Test 2 Results
    case hashStorageSuccess
    case hashStorageFailure
    case hashRetrievalSuccess
    case hashRetrievalFailure
    case hashDeletionSuccess
    case hashDeletionFailure
    case hashDeletionVerifySuccess
    case hashDeletionVerifyFailure

    // Test 3 Results
    case attachmentValidationSuccess // Allowed when should be
    case attachmentValidationFailure // Blocked when should be allowed
    case blockedAttachmentDetectionSuccess // Blocked when should be
    case blockedAttachmentDetectionFailure // Allowed when should be blocked

    // Test 4 Results
    case messageSendSuccess
    case messageSendFailure
    case duplicateDetectionSuccess
    case duplicateDetectionFailure
    case modifiedContentSuccess
    case modifiedContentFailure

    var description: String {
        switch self {
        case .awsConnectionSuccess: return "AWS Connection Validation Success"
        case .awsConnectionFailure: return "AWS Connection Validation Failure"
        case .hashStorageSuccess: return "DynamoDB Hash Storage Success"
        case .hashStorageFailure: return "DynamoDB Hash Storage Failure"
        case .hashRetrievalSuccess: return "DynamoDB Hash Retrieval Success"
        case .hashRetrievalFailure: return "DynamoDB Hash Retrieval Failure"
        case .hashDeletionSuccess: return "DynamoDB Hash Deletion Success"
        case .hashDeletionFailure: return "DynamoDB Hash Deletion Failure"
        case .hashDeletionVerifySuccess: return "DynamoDB Hash Deletion Verification Success"
        case .hashDeletionVerifyFailure: return "DynamoDB Hash Deletion Verification Failure"
        case .attachmentValidationSuccess: return "Attachment Allowed Validation Success"
        case .attachmentValidationFailure: return "Attachment Allowed Validation Failure"
        case .blockedAttachmentDetectionSuccess: return "Blocked Attachment Detection Success"
        case .blockedAttachmentDetectionFailure: return "Blocked Attachment Detection Failure"
        case .messageSendSuccess: return "Message Send Simulation Success"
        case .messageSendFailure: return "Message Send Simulation Failure"
        case .duplicateDetectionSuccess: return "Duplicate Content Receive Detection Success"
        case .duplicateDetectionFailure: return "Duplicate Content Receive Detection Failure"
        case .modifiedContentSuccess: return "Modified Content Receive Allowed Success"
        case .modifiedContentFailure: return "Modified Content Receive Allowed Failure"
        }
    }

    /// Indicates if the result type represents a successful outcome.
    var isSuccess: Bool {
        switch self {
        case .awsConnectionSuccess,
             .hashStorageSuccess, .hashRetrievalSuccess, .hashDeletionSuccess, .hashDeletionVerifySuccess,
             .attachmentValidationSuccess, .blockedAttachmentDetectionSuccess,
             .messageSendSuccess, .duplicateDetectionSuccess, .modifiedContentSuccess:
            return true
        default:
            return false
        }
    }
}

// --- Mock Attachment ---
// If running standalone, we need a mock TSAttachment.
// If running within Signal tests, this might not be needed or could use an existing mock.
#if !canImport(Signal)
// Define a minimal mock if needed, otherwise assume TSAttachment is available via SignalServiceKit
class TSAttachment {
    let uniqueId: String
    let contentType: String?
    var mockDataForDownload: Data?

    init(uniqueId: String, contentType: String?) {
        self.uniqueId = uniqueId
        self.contentType = contentType
    }

    func dataForDownload() throws -> Data {
        guard let data = mockDataForDownload else {
            throw NSError(domain: "MockAttachmentError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No mock data"])
        }
        return data
    }
}
#else
// Use the existing MockAttachment or a suitable test double from the Signal target
// NOTE: Ensure MockAttachment in Signal target has `uniqueId`, `contentType`, and `mockDataForDownload`.
//       If not, you may need to define a local mock or adjust the Signal target's mock.
typealias MockAttachment = Signal.MockAttachment // Adjust if mock name/location differs
#endif

// MARK: - Script Runner

// This allows the script to be run standalone using `swift duplicate_content_live_test.swift`
// It initializes the test class, runs the tests, and exits.
if CommandLine.arguments.contains("--run-live-test") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    print("Starting Duplicate Content Live Test Runner...")
    let liveTestRunner = DuplicateContentLiveTest()
    Task {
        await liveTestRunner.runTests()
        print("Test run complete. Exiting.")
        exit(0) // Exit explicitly after tests are done
    }
    // Keep the script running until the async Task completes
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 600)) // Timeout after 10 minutes
    print("Script timed out or finished.")
    exit(1) // Exit with error if timeout reached
} else {
    // If run as part of XCTest suite, do nothing here. Tests will be invoked by XCTest.
    print("Detected XCTest environment. Standalone runner bypassed.")
}
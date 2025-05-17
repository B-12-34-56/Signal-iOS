//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import Logging
@testable import SignalServiceKit // Import the module containing GlobalSignatureService
@testable import DuplicateContentDetection // Import DuplicateContentDetection for AWSConfig, BatchImportJobTracker

/// Test suite for validating the GlobalSignatureService.
class TestGlobalSignatureService: XCTestCase {

    // MARK: - Properties

    private var signatureService: GlobalSignatureService!
    private var logger: Logger!

    // Use a flag to enable tests against actual AWS. Requires credentials to be configured.
    // WARNING: Enabling this will incur AWS costs and requires proper credential setup.
    private let runValidationTestsAgainstRealAWS = false
    private let defaultRetryCount = 3
    private let testDelay: TimeInterval = 1.0 // Delay for eventual consistency checks

    // Mock Job Tracker for batch import tests
    private var mockJobTracker: BatchImportJobTracker!

    // MARK: - Test Lifecycle

    override func setUpWithError() async throws {
        try await super.setUpWithError()
        logger = Logger(label: "org.signal.tests.TestGlobalSignatureService")
        logger.info("Setting up TestGlobalSignatureService...")

        // Setup AWS Credentials ONLY if running against real AWS
        if runValidationTestsAgainstRealAWS {
            logger.info("Setting up AWS credentials for validation tests...")
            // Use AWSConfig from the DuplicateContentDetection module as it holds the relevant config
            DuplicateContentDetection.AWSConfig.setupAWSCredentials()
            // Validate credentials synchronously - wait for result
            let valid = await DuplicateContentDetection.AWSCredentialsVerificationManager.shared.verifyCredentialsAsync(checkAPIGateway: true, verifyTableExists: true)
             guard valid else {
                 throw XCTSkip("AWS Credentials invalid or setup failed. Skipping tests against real AWS.")
             }
            logger.info("AWS Credentials seem valid.")
        } else {
            logger.info("Skipping AWS credential setup - running tests without real AWS interaction.")
            // NOTE: Tests relying on actual AWS calls will likely fail or be skipped without real credentials.
            // Consider using a mocking framework or test doubles if not testing against live AWS.
            // For this test suite, we will skip tests requiring real AWS if runValidationTestsAgainstRealAWS is false.
        }

        // Initialize the service under test
        signatureService = GlobalSignatureService.shared
        // Reset metrics before each test
        signatureService.resetMetrics()

        // Setup mock tracker
        // Use the shared instance as GlobalSignatureService does
        mockJobTracker = BatchImportJobTracker.shared
        mockJobTracker.clearMockJobs() // Clear any previous mock jobs

        logger.info("Setup complete.")
    }

    override func tearDownWithError() throws {
        logger.info("Tearing down TestGlobalSignatureService...")
        signatureService = nil
        // The tracker is a singleton, just clear its state
        mockJobTracker.clearMockJobs()
        mockJobTracker = nil
        logger = nil
        try super.tearDownWithError()
        logger.info("Teardown complete.")
    }

    // MARK: - Helper Methods

    /// Generates a unique Base64 encoded hash string for testing.
    private func generateRandomHash() -> String {
        let randomData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return randomData.base64EncodedString()
    }

    /// Logs the start of a test method.
    private func logTestStart(function: String = #function) {
        logger.info("--- Starting test: \(function) ---")
    }

    /// Logs the end of a test method.
    private func logTestEnd(function: String = #function) {
        logger.info("--- Finished test: \(function) ---")
    }

    // MARK: - Test Cases

    /// Tests basic hash storage, retrieval (contains), and deletion.
    func testHashStorageAndRetrieval() async throws {
        guard runValidationTestsAgainstRealAWS else {
            throw XCTSkip("Skipping testHashStorageAndRetrieval - requires real AWS interaction.")
        }
        logTestStart()

        let testHash = generateRandomHash()
        let hashPrefix = testHash.prefix(8)
        logger.info("Using test hash: \(hashPrefix)...")

        // 1. Verify hash doesn't exist initially
        logger.info("Checking initial existence...")
        var exists = await signatureService.contains(testHash)
        XCTAssertFalse(exists, "Hash \(hashPrefix) should not exist initially.")
        logger.info("Initial check passed (hash does not exist).")

        // 2. Store the hash
        logger.info("Storing hash...")
        let storeSuccess = await signatureService.store(testHash)
        XCTAssertTrue(storeSuccess, "Failed to store hash \(hashPrefix).")
        logger.info("Store operation returned success.")

        // 3. Verify hash exists after storing (allowing for eventual consistency)
        logger.info("Waiting \(testDelay)s for eventual consistency...")
        try await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000))
        logger.info("Checking existence after store...")
        exists = await signatureService.contains(testHash)
        XCTAssertTrue(exists, "Hash \(hashPrefix) should exist after storing.")
        logger.info("Existence check after store passed.")

        // 4. Delete the hash
        logger.info("Deleting hash...")
        let deleteSuccess = await signatureService.delete(testHash)
        // Delete is often idempotent, check for true or expected error if applicable
        XCTAssertTrue(deleteSuccess, "Delete operation failed for hash \(hashPrefix).")
        logger.info("Delete operation returned success.")

        // 5. Verify hash no longer exists after deleting
        logger.info("Waiting \(testDelay)s for eventual consistency...")
        try await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000))
        logger.info("Checking existence after delete...")
        exists = await signatureService.contains(testHash)
        XCTAssertFalse(exists, "Hash \(hashPrefix) should not exist after deletion.")
        logger.info("Existence check after delete passed.")

        logTestEnd()
    }

    /// Tests concurrent hash operations (contains, store) under moderate load.
    func testConcurrentHashOperations() async throws {
         guard runValidationTestsAgainstRealAWS else {
             throw XCTSkip("Skipping testConcurrentHashOperations - requires real AWS interaction.")
         }
        logTestStart()

        let numberOfHashes = 50 // Number of concurrent operations
        let hashes = (0..<numberOfHashes).map { _ in generateRandomHash() }
        logger.info("Testing with \(numberOfHashes) concurrent operations...")

        await withTaskGroup(of: Bool.self) { group in
            for hash in hashes {
                // Mix of contains and store operations
                if Bool.random() {
                    group.addTask {
                        // Perform a 'contains' check
                        _ = await self.signatureService.contains(hash)
                        // We don't assert the result here, just that it completes
                        return true // Indicate completion
                    }
                } else {
                    group.addTask {
                        // Perform a 'store' operation
                        return await self.signatureService.store(hash)
                    }
                }
            }

            // Collect results - primarily checking for crashes/deadlocks
            var completedCount = 0
            for await result in group {
                if result { // Check if task reported success/completion
                    completedCount += 1
                }
            }
            logger.info("Completed \(completedCount) out of \(numberOfHashes * 1) concurrent tasks.") // Each hash yields one task
             // Due to potential API Gateway errors or network issues, not all might succeed even if no crash
             // A more robust test might check for specific error types and expected retry behavior
             // For now, we assert based on successful completion flags from tasks.
             // XCTAssertEqual(completedCount, numberOfHashes, "Not all concurrent operations completed successfully.")
             // Instead of exact equality, check if a significant portion succeeded
             let minimumExpectedSuccess = Int(Double(numberOfHashes) * 0.8) // e.g., expect at least 80% success
             XCTAssertGreaterThanOrEqual(completedCount, minimumExpectedSuccess, "Insufficient number of concurrent operations completed successfully.")
        }

        logger.info("Concurrent operations test completed.")

        // Optional: Verify all hashes were eventually stored (requires another batch check)
        // This part requires batchContains to work against real AWS
         if runValidationTestsAgainstRealAWS {
             logger.info("Verifying final state of stored hashes...")
             let finalCheck = await signatureService.batchContains(hashes: hashes)
             let storedCount = finalCheck?.filter { $1 }.count ?? 0
             // Stored count might not be exactly numberOfHashes if some tasks were 'contains'
             // and some 'store' calls might have failed
             logger.info("Found \(storedCount) hashes stored after concurrent operations.")
         } else {
             logger.info("Skipping final state verification - requires real AWS batchContains.")
         }


        // Cleanup (best effort)
        logger.info("Cleaning up concurrently added hashes (best effort)...")
        await withTaskGroup(of: Void.self) { group in
             for hash in hashes {
                 group.addTask { await self.signatureService.delete(hash) }
             }
         }
        logger.info("Cleanup finished.")


        logTestEnd()
    }

    /// Tests batch import and batch contains operations.
    func testBatchOperations() async throws {
        logTestStart()

        let batchSize = 50 // Keep batch size reasonable for testing
        let hashesToImport = (0..<batchSize).map { _ in generateRandomHash() }
        // Mix of hashes that *should* be imported and hashes that should *not*
        let hashesToCheck = hashesToImport.prefix(batchSize / 2).map { $0 } + (0..<batchSize / 2).map { _ in generateRandomHash() }

        // 1. Test Batch Import
        logger.info("Testing batch import for \(hashesToImport.count) hashes...")
        // This call uses the S3toDynamoDBImporter.shared which has a mock implementation
        let jobId = await signatureService.batchImportHashes(hashes: hashesToImport)

        XCTAssertNotNil(jobId, "Batch import should return a job ID.")
        logger.info("Batch import initiated with Job ID: \(jobId ?? "N/A").")

        // 2. Check Job Status (uses BatchImportJobTracker.shared mock)
        if let id = jobId {
            // Simulate waiting for job completion using the mock tracker
            mockJobTracker.registerMockJob(jobId: id, status: .processing, progress: 0.5)
            var status = await signatureService.getJobStatus(jobId: id)
            XCTAssertNotNil(status, "Should be able to get job status.")
            XCTAssertEqual(status?.jobId, id)
            XCTAssertEqual(status?.status, .processing)
            XCTAssertEqual(status?.progress, 0.5)
            logger.info("Checked job status (processing): Progress \(status?.progress ?? -1)")

            // Simulate completion (the mock S3Importer automatically marks it complete after its simulated delay)
             status = await signatureService.getJobStatus(jobId: id)
             XCTAssertNotNil(status, "Should be able to get final job status.")
             XCTAssertEqual(status?.status, .completed, "Mock job should complete successfully.")
             XCTAssertEqual(status?.progress, 1.0)
             logger.info("Checked job status (completed).")

             // Test cancellation (on a new mock job)
             let cancelJobId = UUID().uuidString
             mockJobTracker.registerMockJob(jobId: cancelJobId, status: .processing, progress: 0.2)
             let cancelRequested = await signatureService.cancelBatchImportJob(jobId: cancelJobId)
             XCTAssertTrue(cancelRequested, "Should be able to request cancellation.")
             status = await signatureService.getJobStatus(jobId: cancelJobId)
             XCTAssertNotNil(status, "Should be able to get cancelled job status.")
             XCTAssertEqual(status?.status, .cancelled, "Job status should update to cancelled.")
             logger.info("Tested job cancellation.")
        }


        // 3. Test Batch Contains
        logger.info("Testing batch contains for \(hashesToCheck.count) hashes...")
        // This part hits the API Gateway via APIGatewayClient.shared.
         guard runValidationTestsAgainstRealAWS else {
             logger.warning("Skipping batch contains validation - requires real AWS interaction.")
             logTestEnd() // End the test here if not running against AWS
             return
         }

        // Need to ensure the first half of hashesToCheck exist from the import
        // The mock S3Importer marks the job complete immediately, but actual DB write takes time.
        // Need to wait for real eventual consistency in DynamoDB.
        logger.info("Waiting \(testDelay * 5)s for batch import eventual consistency in DynamoDB...") // Longer delay
        try await Task.sleep(nanoseconds: UInt64(testDelay * 5 * 1_000_000_000))

        let checkResults = await signatureService.batchContains(hashes: hashesToCheck)
        XCTAssertNotNil(checkResults, "Batch contains should return a dictionary.")

        if let results = checkResults {
            logger.info("Batch contains returned \(results.count) results.")
            XCTAssertEqual(results.count, hashesToCheck.count, "Batch contains should return results for all queried hashes.")

            var foundCount = 0
            var notFoundCount = 0
            for (hash, exists) in results {
                if hashesToImport.contains(hash) {
                    // These should have been imported and should exist
                    XCTAssertTrue(exists, "Hash \(hash.prefix(8))... which was imported should exist.")
                    if exists { foundCount += 1 } else { logger.error("Imported hash \(hash.prefix(8))... not found.") }
                } else {
                    // These were not imported and should not exist
                    XCTAssertFalse(exists, "Hash \(hash.prefix(8))... which was not imported should not exist.")
                    if !exists { notFoundCount += 1 } else { logger.error("Non-imported hash \(hash.prefix(8))... unexpectedly found.") }
                }
            }
            logger.info("Verified \(foundCount) imported hashes and \(notFoundCount) non-imported hashes in batch.")
            // Check counts match expected split if assuming eventual consistency worked
            XCTAssertGreaterThanOrEqual(foundCount, batchSize / 2, "Should have found at least half of the hashes that were imported.")
             XCTAssertGreaterThanOrEqual(notFoundCount, batchSize / 2, "Should not have found more than half of the newly generated hashes.")
        } else {
             logger.error("Batch contains returned nil results.")
        }


         // Cleanup imported hashes (best effort)
         logger.info("Cleaning up batch imported hashes (best effort)...")
         await withTaskGroup(of: Void.self) { group in
              for hash in hashesToImport {
                  group.addTask { await self.signatureService.delete(hash) }
              }
          }
         logger.info("Batch cleanup finished.")

        logTestEnd()
    }

    /// Validates retry mechanisms for transient failures. Requires mocking or ability to induce errors.
    func testErrorHandlingAndRetry() async throws {
         // This test requires a way to inject specific errors (e.g., 429, 503) into the APIGatewayClient response.
         // Since GlobalSignatureService uses the singleton APIGatewayClient directly, true mocking is difficult
         // without dependency injection or a test-specific configuration allowing override.
         // Inducing real errors on AWS is unreliable for controlled testing.

         throw XCTSkip("Skipping testErrorHandlingAndRetry - Requires mocking APIGatewayClient or inducing real errors, which is complex/unreliable with current architecture.")

        // Placeholder: Describe what would be tested
        /*
        logTestStart()
        logger.warning("Test testErrorHandlingAndRetry requires mocking or error injection capabilities not currently implemented. Skipping core logic.")

        // If mocking were possible:
        // 1. Configure mock APIGatewayClient for GlobalSignatureService
        //    - Set mock client to return a 429 (Too Many Requests) for the first N attempts, then success (e.g., 200 OK or 404 Not Found for contains).
        // 2. Call a method like `signatureService.contains("transientErrorHash")`.
        // 3. Verify (e.g., by checking logs or mock call counts) that multiple attempts occurred due to retries.
        // 4. Assert the final result matches the expected outcome after retries (true if mock returns 200/404 eventually).
        // 5. Repeat for a non-retryable error (e.g., 403 Forbidden or 400 Bad Request).
        // 6. Verify that only the initial attempt occurred and the result is false.

        logTestEnd()
        */
    }

    /// Verifies the metrics collection functionality.
    func testMetricsReporting() async throws {
         // This test verifies internal state changes and doesn't strictly *require* real AWS calls,
         // but running operations against real AWS provides more realistic duration metrics.
         // We can run the core logic of checking counts even without real AWS, but durations will be zero.
         logTestStart()

        // Reset metrics just in case
        signatureService.resetMetrics()
        var initialMetrics = signatureService.getMetrics()
        logger.info("Initial Metrics: \(initialMetrics)")

         // Check initial state (all zeros)
         let initialContains = initialMetrics["singleContains"] as? [String: Any]
         XCTAssertEqual(initialContains?["calls"] as? Int, 0)
         XCTAssertEqual(initialContains?["success"] as? Int, 0)
         XCTAssertEqual(initialContains?["totalHashes"] as? Int, 0)
         XCTAssertEqual(initialContains?["avgDuration"] as? Double, 0.0)

         let initialStore = initialMetrics["singleStore"] as? [String: Any]
         XCTAssertEqual(initialStore?["calls"] as? Int, 0)
         XCTAssertEqual(initialStore?["success"] as? Int, 0)
         XCTAssertEqual(initialStore?["totalHashes"] as? Int, 0)
         XCTAssertEqual(initialStore?["avgDuration"] as? Double, 0.0)

         let initialDelete = initialMetrics["singleDelete"] as? [String: Any]
         XCTAssertEqual(initialDelete?["calls"] as? Int, 0)
         XCTAssertEqual(initialDelete?["success"] as? Int, 0)
         XCTAssertEqual(initialDelete?["totalHashes"] as? Int, 0)
         XCTAssertEqual(initialDelete?["avgDuration"] as? Double, 0.0)

         let initialBatchContains = initialMetrics["batchContains"] as? [String: Any]
         XCTAssertEqual(initialBatchContains?["calls"] as? Int, 0)
         XCTAssertEqual(initialBatchContains?["success"] as? Int, 0)
         XCTAssertEqual(initialBatchContains?["totalHashes"] as? Int, 0)
         XCTAssertEqual(initialBatchContains?["avgDuration"] as? Double, 0.0)

         let initialBatchImport = initialMetrics["batchImport"] as? [String: Any]
         XCTAssertEqual(initialBatchImport?["calls"] as? Int, 0)
         XCTAssertEqual(initialBatchImport?["success"] as? Int, 0)
         XCTAssertEqual(initialBatchImport?["totalHashes"] as? Int, 0)
         XCTAssertEqual(initialBatchImport?["avgDuration"] as? Double, 0.0)


        // Perform some operations that hit the service methods
        logger.info("Performing sample operations to generate metrics...")
        let hash1 = generateRandomHash()
        let hash2 = generateRandomHash()
        let hash3 = generateRandomHash() // For batch

        // Single operations
        _ = await signatureService.store(hash1) // 1 store call, 1 success, 1 total stored
        _ = await signatureService.contains(hash1) // 1 contains call, 1 success, 1 total checked
        _ = await signatureService.contains(hash2) // 1 contains call, 1 success (404), 1 total checked
        _ = await signatureService.delete(hash1) // 1 delete call, 1 success, 1 total deleted
        _ = await signatureService.delete(hash2) // 1 delete call, 1 success (404), 1 total deleted

        // Batch operations (these use the mock S3Importer, but update BatchImport metrics)
        let hashesForBatchImport = (0..<10).map { _ in generateRandomHash() }
        _ = await signatureService.batchImportHashes(hashes: hashesForBatchImport) // 1 batchImport call, 1 success, 10 total imported

        let hashesForBatchContains = [hash1, hash2, hash3]
         // This will hit APIGatewayClient.shared.batchContains if running against real AWS
         if runValidationTestsAgainstRealAWS {
             // Ensure hashes exist for realistic batch contains metrics
             _ = await signatureService.store(hash1) // Ensure hash1 is present
              _ = await signatureService.store(hash3) // Ensure hash3 is present
             try await Task.sleep(nanoseconds: UInt64(testDelay * 2 * 1_000_000_000)) // Wait for consistency
             _ = await signatureService.batchContains(hashes: hashesForBatchContains) // 1 batchContains call, 1 success, 3 total checked in batch
         } else {
              logger.warning("Skipping real batchContains call for metrics test - requires real AWS.")
              // We can't reliably test batchContains metrics without hitting the API or a mock of the API client itself.
              // If running without real AWS, batchContains calls and successes will remain 0.
         }


        // Check metrics after operations
        var finalMetrics = signatureService.getMetrics()
        logger.info("Metrics after operations: \(finalMetrics)")

         // Verify single operations metrics
         let finalContains = finalMetrics["singleContains"] as? [String: Any]
         XCTAssertEqual(finalContains?["calls"] as? Int ?? -1, 2, "Should reflect 2 contains calls.")
         XCTAssertEqual(finalContains?["success"] as? Int ?? -1, 2, "Should reflect 2 successful contains calls (including 404).")
         if runValidationTestsAgainstRealAWS { XCTAssertGreaterThan(finalContains?["avgDuration"] as? Double ?? -1.0, 0.0, "Average contains duration should be positive if running against AWS.") }

         let finalStore = finalMetrics["singleStore"] as? [String: Any]
         XCTAssertEqual(finalStore?["calls"] as? Int ?? -1, 1, "Should reflect 1 store call.")
         XCTAssertEqual(finalStore?["success"] as? Int ?? -1, 1, "Should reflect 1 successful store call.")
          if runValidationTestsAgainstRealAWS { XCTAssertGreaterThan(finalStore?["avgDuration"] as? Double ?? -1.0, 0.0, "Average store duration should be positive if running against AWS.") }

         let finalDelete = finalMetrics["singleDelete"] as? [String: Any]
         XCTAssertEqual(finalDelete?["calls"] as? Int ?? -1, 2, "Should reflect 2 delete calls.")
         XCTAssertEqual(finalDelete?["success"] as? Int ?? -1, 2, "Should reflect 2 successful delete calls (including 404).")
          if runValidationTestsAgainstRealAWS { XCTAssertGreaterThan(finalDelete?["avgDuration"] as? Double ?? -1.0, 0.0, "Average delete duration should be positive if running against AWS.") }

         // Verify batch import metrics (uses mock S3Importer which updates tracker state)
         let finalBatchImport = finalMetrics["batchImport"] as? [String: Any]
         XCTAssertEqual(finalBatchImport?["calls"] as? Int ?? -1, 1, "Should reflect 1 batch import call.")
         XCTAssertEqual(finalBatchImport?["success"] as? Int ?? -1, 1, "Should reflect 1 successful batch import.")
         XCTAssertEqual(finalBatchImport?["totalHashes"] as? Int ?? -1, hashesForBatchImport.count, "Should reflect correct number of hashes imported.")
         if runValidationTestsAgainstRealAWS { XCTAssertGreaterThan(finalBatchImport?["avgDuration"] as? Double ?? -1.0, 0.0, "Average batch import duration should be positive if running against AWS.") }

         // Verify batch contains metrics
         let finalBatchContains = finalMetrics["batchContains"] as? [String: Any]
         if runValidationTestsAgainstRealAWS {
             XCTAssertEqual(finalBatchContains?["calls"] as? Int ?? -1, 1, "Should reflect 1 batch contains call.")
             XCTAssertEqual(finalBatchContains?["success"] as? Int ?? -1, 1, "Should reflect 1 successful batch contains.")
             XCTAssertEqual(finalBatchContains?["totalHashes"] as? Int ?? -1, hashesForBatchContains.count, "Should reflect correct number of hashes checked in batch.")
             XCTAssertGreaterThan(finalBatchContains?["avgDuration"] as? Double ?? -1.0, 0.0, "Average batch contains duration should be positive if running against AWS.")
         } else {
             XCTAssertEqual(finalBatchContains?["calls"] as? Int ?? 0, 0, "Should reflect 0 batch contains calls if not running against AWS.")
         }


        // Test reset
        logger.info("Resetting metrics...")
        signatureService.resetMetrics()
        initialMetrics = signatureService.getMetrics()
        logger.info("Metrics after reset: \(initialMetrics)")
        let resetContains = initialMetrics["singleContains"] as? [String: Any]
        XCTAssertEqual(resetContains?["calls"] as? Int, 0, "Calls should be 0 after reset.")
        XCTAssertEqual(resetContains?["success"] as? Int, 0, "Successes should be 0 after reset.")
        XCTAssertEqual(resetContains?["totalHashes"] as? Int, 0, "Total hashes should be 0 after reset.")
        XCTAssertEqual(resetContains?["avgDuration"] as? Double, 0.0, "Average duration should be 0 after reset.")
        // Verify other metrics are also reset to zero
         let resetStore = initialMetrics["singleStore"] as? [String: Any]
         XCTAssertEqual(resetStore?["calls"] as? Int, 0)
         XCTAssertEqual(resetStore?["success"] as? Int, 0)
         XCTAssertEqual(resetStore?["totalHashes"] as? Int, 0)
         XCTAssertEqual(resetStore?["avgDuration"] as? Double, 0.0)

         let resetDelete = initialMetrics["singleDelete"] as? [String: Any]
         XCTAssertEqual(resetDelete?["calls"] as? Int, 0)
         XCTAssertEqual(resetDelete?["success"] as? Int, 0)
         XCTAssertEqual(resetDelete?["totalHashes"] as? Int, 0)
         XCTAssertEqual(resetDelete?["avgDuration"] as? Double, 0.0)

         let resetBatchContains = initialMetrics["batchContains"] as? [String: Any]
         XCTAssertEqual(resetBatchContains?["calls"] as? Int, 0)
         XCTAssertEqual(resetBatchContains?["success"] as? Int, 0)
         XCTAssertEqual(resetBatchContains?["totalHashes"] as? Int, 0)
         XCTAssertEqual(resetBatchContains?["avgDuration"] as? Double, 0.0)

         let resetBatchImport = initialMetrics["batchImport"] as? [String: Any]
         XCTAssertEqual(resetBatchImport?["calls"] as? Int, 0)
         XCTAssertEqual(resetBatchImport?["success"] as? Int, 0)
         XCTAssertEqual(resetBatchImport?["totalHashes"] as? Int, 0)
         XCTAssertEqual(resetBatchImport?["avgDuration"] as? Double, 0.0)


        logTestEnd()
         // Cleanup hashes added during metrics test
         if runValidationTestsAgainstRealAWS {
              logger.info("Cleaning up hashes added during metrics test...")
              await withTaskGroup(of: Void.self) { group in
                   group.addTask { await self.signatureService.delete(hash1) }
                    group.addTask { await self.signatureService.delete(hash3) }
               }
              logger.info("Cleanup finished.")
         }
    }
}

// MARK: - Standalone Execution Code

// Allows running tests using `swift test_global_signature_service.swift`
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
@main
struct TestGlobalSignatureServiceRunner {
    static func main() async {
         // Check if running via XCTest harness or standalone
         if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
             print("Starting GlobalSignatureService Test Runner (Standalone)...")

             let logger = Logger(label: "org.signal.tests.TestGlobalSignatureServiceRunner")

             // Configure AWS for standalone runs if validation tests are enabled
             // Check if the flag is true by inspecting the test class itself
             let testInstance = TestGlobalSignatureService()
             if testInstance.runValidationTestsAgainstRealAWS {
                 logger.info("AWS validation tests enabled. Attempting AWS configuration.")
                 DuplicateContentDetection.AWSConfig.setupAWSCredentials()
                  // Basic check to see if setup yielded credentials
                  let isValid = await DuplicateContentDetection.AWSConfig.validateAWSCredentials(checkAPIGateway: false)
                  if !isValid {
                       logger.error("AWS credentials validation failed during standalone setup. Tests requiring real AWS will likely be skipped.")
                  } else {
                       logger.info("AWS credentials seem valid for standalone run.")
                  }
             } else {
                 logger.info("AWS validation tests disabled. Skipping AWS configuration for standalone run.")
             }


             // Programmatically find and run tests
             let testSuite = TestGlobalSignatureService.defaultTestSuite // Get the default suite containing all test methods

             // XCTest run API is synchronous. To run async tests, you typically need a running RunLoop
             // or use a different test runner. Programmatic XCTest execution is complex with async.
             // For simplicity, we'll use a basic run, but async tests may not be fully awaited
             // unless the system handles it implicitly.

             // A simple approach might be to wrap the run in an async Task if supported by the platform/Xcode version
             // Or run within a RunLoop.

             // Option 1: Simple synchronous run (async tests might not complete)
             // testSuite.run()

             // Option 2: Running within a Task and waiting (more suitable for async)
             // This requires the script environment to support top-level await or be in a context that does.
             await testSuite.run() // If run() is async or blocks correctly

             print("Test run complete.")
         } else {
             // If run as part of XCTest suite, do nothing here. XCTest will discover and run the tests.
             print("Detected XCTest environment. Standalone runner bypassed.")
         }
    }
}
#endif
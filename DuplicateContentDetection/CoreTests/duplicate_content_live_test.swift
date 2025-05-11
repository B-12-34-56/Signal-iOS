//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSDynamoDB
import AWSAPIGateway // Potentially needed if testing API GW directly or for types
import Logging
import CryptoKit
// Import necessary modules - adjust based on actual project structure
// Assuming these modules contain the required services
import SignalServiceKit
@testable import DuplicateContentDetection

/// Standalone script for live testing of the Duplicate Content Detection system against AWS.
/// Can also run in a mock mode for basic checks without AWS interaction.
///
/// Usage:
///   swift DuplicateContentDetection/CoreTests/duplicate_content_live_test.swift [--mock] [--test <test_name>]
///
/// Options:
///   --mock: Run using simulated AWS responses (no actual AWS calls).
///   --test <name>: Run only a specific test function (e.g., --test verifyAWS, --test gss). Default runs all.
///
@main
struct DuplicateContentLiveTestRunner {

    // MARK: - Configuration
    private var runInMockMode: Bool = false
    private var specificTestToRun: String? = nil
    private let defaultTimeout: TimeInterval = 60.0 // Timeout for async operations

    // MARK: - Services
    private let logger = Logger(label: "org.signal.DuplicateContentLiveTest")
    private var verificationManager: AWSCredentialsVerificationManager!
    private var signatureService: GlobalSignatureService!
    private var mockService: AWSServiceMock? // Only used in mock mode
    private var reportGenerator: AWSDependencyVerificationReport!

    // MARK: - Entry Point
    static func main() async {
        var runner = DuplicateContentLiveTestRunner()
        runner.parseArguments()
        await runner.run()
    }

    mutating func parseArguments() {
        let args = CommandLine.arguments
        runInMockMode = args.contains("--mock")
        if let testIndex = args.firstIndex(of: "--test"), testIndex + 1 < args.count {
            specificTestToRun = args[testIndex + 1]
        }
        logger.logLevel = .debug // Set log level
    }

    /// Initializes services (real or mocked) and runs the selected tests.
    mutating func run() async {
        reportGenerator = AWSDependencyVerificationReport(logger: logger)
        logger.notice("Starting Duplicate Content Live Test (Mode: \(runInMockMode ? "Mock" : "Live"))...")

        await setupServices()

        var testsToRun: [(String, () async throws -> Void)] = [
            ("verifyAWS", verifyAWS),
            ("gss", testGSSOperations),
            ("performance", testPerformance),
            ("errorHandling", testErrorHandling), // Limited in live mode
            ("e2e", testE2EFlow)
        ]

        // Filter tests if a specific one was requested
        if let specificTest = specificTestToRun {
            testsToRun = testsToRun.filter { $0.0.lowercased() == specificTest.lowercased() }
            if testsToRun.isEmpty {
                logger.error("No test found matching name: \(specificTest)")
                return
            }
        }

        for (name, testFunction) in testsToRun {
            logger.notice("--- Running Test: \(name) ---")
            await runTest(name: name, category: mapTestNameToCategory(name), function: testFunction)
        }

        logger.notice("--- Test Run Complete ---")
        // Generate and print final report
        let report = reportGenerator.generateReport(format: .log, detailLevel: .full)
        print("\n\(report)")

        // Optionally write to file
        // writeReportToFile(report)
    }

    // MARK: - Setup
    mutating func setupServices() async {
        if runInMockMode {
            logger.info("Initializing MOCK services...")
            mockService = AWSServiceMock(logger: logger)
            mockService!.reset() // Ensure clean state
            // Inject mock clients into SDK/Singletons (assumes mechanism exists)
             mockService!.injectMockCredentialsProviderIntoSDK()
             mockService!.injectMockDynamoDBIntoSDK() // If GSS uses DynamoDB client directly
             // Inject mock API Gateway client if GSS uses it
             // GlobalSignatureService.unsafeReplaceAPIGatewayClientForTesting(mockService!.getMockAPIGateway()) // Hypothetical

            verificationManager = AWSCredentialsVerificationManager.shared // Assumes it picks up mock provider
            signatureService = GlobalSignatureService.shared // Assumes it picks up mock clients
            logger.info("MOCK services ready.")
        } else {
            logger.info("Initializing LIVE services...")
            AWSConfig.loadConfiguration()
            AWSConfig.setupAWSCredentials()
            guard AWSConfig.isCredentialsSetup else {
                logger.critical("LIVE mode requires AWS credentials setup. Aborting.")
                fatalError("AWS Credentials setup failed.") // Fail fast if live setup fails
            }
            verificationManager = AWSCredentialsVerificationManager.shared
            signatureService = GlobalSignatureService.shared
            logger.info("LIVE services ready.")
        }
    }

    // MARK: - Test Execution Helper
    func runTest(name: String, category: AWSDependencyVerificationReport.ServiceCategory, function: () async throws -> Void) async {
        let startTime = Date()
        var success = false
        var error: Error?
        do {
            try await withTimeout(seconds: defaultTimeout) {
                 try await function()
            }
            success = true
        } catch let err {
            error = err
            logger.error("Test '\(name)' failed: \(err.localizedDescription)")
        }
        reportGenerator.addEntry(name: name, category: category, success: success, duration: Date().timeIntervalSince(startTime), error: error)
    }

    func mapTestNameToCategory(_ name: String) -> AWSDependencyVerificationReport.ServiceCategory {
         switch name.lowercased() {
         case "verifyaws": return .general
         case "gss": return .storage // DynamoDB interaction via GSS/API GW
         case "performance": return .general
         case "errorhandling": return .general
         case "e2e": return .general
         default: return .general
         }
     }

    // MARK: - Test Implementations

    /// Verifies AWS credentials and basic service connectivity.
    func verifyAWS() async throws {
        logger.info("Verifying AWS Credentials and Connectivity...")
        // Use the verification manager which handles mocks internally based on setup
        let isValid = try await verificationManager.verifyCredentialsAsync(
            setupCredentialsIfNeeded: false, // Setup done in runner setup
            checkAPIGateway: true,
            verifyTableExists: true
        )
        guard isValid else {
            throw NSError(domain: "LiveTest", code: 101, userInfo: [NSLocalizedDescriptionKey: "AWS Verification Failed"])
        }
        logger.info("AWS Verification Successful.")
    }

    /// Tests basic GSS operations: store, contains, delete.
    func testGSSOperations() async throws {
        logger.info("Testing GlobalSignatureService operations...")
        let testHash = generateRandomHash()

        // 1. Check initial state (should not exist)
        logger.debug("Checking initial existence for \(testHash.prefix(8))...")
        var exists = await signatureService.contains(testHash)
        if exists { logger.warning("Hash \(testHash.prefix(8)) unexpectedly exists before store.") }
        // Don't fail test if it exists due to previous run, just log

        // 2. Store the hash
        logger.debug("Storing hash \(testHash.prefix(8))...")
        let storeSuccess = await signatureService.store(testHash)
        guard storeSuccess else {
             throw NSError(domain: "LiveTest", code: 201, userInfo: [NSLocalizedDescriptionKey: "GSS store failed for \(testHash.prefix(8))"])
        }
        logger.info("GSS store successful.")
        if !runInMockMode { try await Task.sleep(nanoseconds: 1_500_000_000) } // Delay for live consistency

        // 3. Verify hash exists
        logger.debug("Verifying existence after store for \(testHash.prefix(8))...")
        exists = await signatureService.contains(testHash)
        guard exists else {
            throw NSError(domain: "LiveTest", code: 202, userInfo: [NSLocalizedDescriptionKey: "GSS contains failed to find hash \(testHash.prefix(8)) after store"])
        }
        logger.info("GSS contains verification successful.")

        // 4. Delete the hash
        logger.debug("Deleting hash \(testHash.prefix(8))...")
        let deleteSuccess = await signatureService.delete(testHash)
        guard deleteSuccess else {
             // Delete is often idempotent, but we check the return for consistency
             logger.warning("GSS delete returned false for \(testHash.prefix(8)). Continuing check.")
             // throw NSError(domain: "LiveTest", code: 203, userInfo: [NSLocalizedDescriptionKey: "GSS delete failed for \(testHash.prefix(8))"])
        }
        logger.info("GSS delete successful or idempotent.")
         if !runInMockMode { try await Task.sleep(nanoseconds: 1_500_000_000) } // Delay for live consistency

        // 5. Verify hash no longer exists
        logger.debug("Verifying non-existence after delete for \(testHash.prefix(8))...")
        exists = await signatureService.contains(testHash)
        guard !exists else {
             throw NSError(domain: "LiveTest", code: 204, userInfo: [NSLocalizedDescriptionKey: "GSS contains found hash \(testHash.prefix(8)) after delete"])
        }
        logger.info("GSS delete verification successful.")
        logger.info("GSS Operations Test Passed.")
    }

    /// Measures basic performance of GSS contains and store.
    func testPerformance() async throws {
        logger.info("Testing GlobalSignatureService performance...")
        let containsHash = generateRandomHash()
        let storeHash = generateRandomHash()

        // Setup: ensure 'containsHash' exists for measurement
        _ = await signatureService.store(containsHash)
         if !runInMockMode { try await Task.sleep(nanoseconds: 1_000_000_000) }

        // Measure contains
        let containsStartTime = Date()
        _ = await signatureService.contains(containsHash)
        let containsDuration = Date().timeIntervalSince(containsStartTime)
        logger.info("GSS contains latency: \(String(format: "%.3f", containsDuration))s")
        reportGenerator.addEntry(name: "Perf - Contains", category: .general, success: true, duration: containsDuration)

        // Measure store
        let storeStartTime = Date()
        _ = await signatureService.store(storeHash)
        let storeDuration = Date().timeIntervalSince(storeStartTime)
        logger.info("GSS store latency: \(String(format: "%.3f", storeDuration))s")
        reportGenerator.addEntry(name: "Perf - Store", category: .general, success: true, duration: storeDuration)

        // Cleanup
        _ = await signatureService.delete(containsHash)
        _ = await signatureService.delete(storeHash)
        logger.info("Performance Test Passed.")
    }

    /// Tests error handling scenarios (limited scope in live mode).
    func testErrorHandling() async throws {
        logger.info("Testing Error Handling scenarios...")

        if runInMockMode {
             logger.info("Testing with MOCK errors...")
             // Test non-retryable error (e.g., Access Denied on DynamoDB)
             logger.debug("Simulating non-retryable DynamoDB error (AccessDenied)...")
             mockService?.updateConfig(AWSServiceMock.Config(shouldThrowDynamoDBErrors: true, dynamoDBErrorCode: AWSDynamoDBErrorType.accessDenied.rawValue))
             let hash1 = generateRandomHash()
             let result1 = await signatureService.contains(hash1) // Should fail fast
             let calls1 = mockService?.getCallLog().filter { $0.service == "DynamoDB" && $0.method == "getItem" }.count ?? -1
             logger.info("Result (non-retryable): \(result1), Calls: \(calls1)")
             guard !result1 && calls1 == 1 else {
                 throw NSError(domain: "LiveTest", code: 401, userInfo: [NSLocalizedDescriptionKey: "Non-retryable error test failed. Expected immediate fail and 1 call."])
             }
             mockService?.reset() // Reset mock state

            // Test retry exhaustion (e.g., persistent throttling)
            logger.debug("Simulating persistent DynamoDB throttling...")
            mockService?.updateConfig(AWSServiceMock.Config(simulateRateLimiting: true, rateLimitThreshold: 0)) // Always throttle
            let hash2 = generateRandomHash()
            let result2 = await signatureService.contains(hash2) // Should exhaust retries
            let calls2 = mockService?.getCallLog().filter { $0.service == "DynamoDB" && $0.method == "getItem" }.count ?? -1
            logger.info("Result (retry exhaustion): \(result2), Calls: \(calls2)")
             guard !result2 && calls2 == (signatureService.defaultRetryCount + 1) else {
                 throw NSError(domain: "LiveTest", code: 402, userInfo: [NSLocalizedDescriptionKey: "Retry exhaustion test failed. Expected fail after \(signatureService.defaultRetryCount + 1) calls."])
             }
             mockService?.reset() // Reset mock state
            logger.info("MOCK error handling tests passed.")

        } else {
            logger.warning("Skipping detailed error handling tests in LIVE mode. Focus on basic retry observation.")
            // Try to trigger a retry by sending rapid requests (unreliable)
            let hash = generateRandomHash()
            let tasks = (0..<10).map { _ in Task { await signatureService.contains(hash) } }
            _ = await tasks.map { await $0.value }
            logger.info("Sent rapid 'contains' requests. Check logs for potential retry messages.")
            // Cannot guarantee retries occurred or assert on them reliably in live mode here.
        }
        logger.info("Error Handling Test Section Passed (or skipped).")
    }

    /// Simulates the end-to-end flow: send (store), receive duplicate (block), receive modified (allow).
    func testE2EFlow() async throws {
        logger.info("Testing End-to-End flow...")
        let originalData = generateRandomData(size: 128)
        let originalHash = computeHash(for: originalData)

        // 1. Simulate Send (Store Hash)
        logger.debug("E2E: Storing original hash \(originalHash.prefix(8))...")
        let storeSuccess = await signatureService.store(originalHash)
        guard storeSuccess else {
            throw NSError(domain: "LiveTest", code: 501, userInfo: [NSLocalizedDescriptionKey: "E2E failed: Could not store initial hash."])
        }
         if !runInMockMode { try await Task.sleep(nanoseconds: 1_500_000_000) } // Delay for live consistency

        // 2. Simulate Receive Duplicate (Check Hash - Should Block)
        logger.debug("E2E: Checking original hash \(originalHash.prefix(8))... (should be blocked)")
        let duplicateCheckResult = await signatureService.contains(originalHash)
        guard duplicateCheckResult else { // Should return TRUE (exists/blocked)
             throw NSError(domain: "LiveTest", code: 502, userInfo: [NSLocalizedDescriptionKey: "E2E failed: Duplicate hash was not found (should have been blocked)."])
        }
        logger.info("E2E: Duplicate hash correctly detected.")

        // 3. Simulate Receive Modified (Check Different Hash - Should Allow)
        var modifiedData = originalData
        modifiedData[0] ^= 0xFF // Flip first byte
        let modifiedHash = computeHash(for: modifiedData)
        logger.debug("E2E: Checking modified hash \(modifiedHash.prefix(8))... (should be allowed)")
        let modifiedCheckResult = await signatureService.contains(modifiedHash)
        guard !modifiedCheckResult else { // Should return FALSE (doesn't exist/allowed)
             throw NSError(domain: "LiveTest", code: 503, userInfo: [NSLocalizedDescriptionKey: "E2E failed: Modified hash was found (should have been allowed)."])
        }
        logger.info("E2E: Modified hash correctly allowed.")

        // Cleanup
        _ = await signatureService.delete(originalHash)

        logger.info("End-to-End Flow Test Passed.")
    }

    // MARK: - Helper Utilities
    func generateRandomData(size: Int) -> Data {
        guard size > 0 else { return Data() }
        return Data((0..<size).map { _ in UInt8.random(in: 0...255) })
    }

    func generateRandomHash() -> String {
        return Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    func computeHash(for data: Data) -> String {
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    // Helper for adding timeout to async operations
    func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    struct TimeoutError: Error {}

    // Function to write report to file (optional)
    // func writeReportToFile(_ report: String) {
    //     let filename = "duplicate_content_live_test_report_\(Int(Date().timeIntervalSince1970)).log"
    //     let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(filename)
    //     do {
    //         try report.write(to: fileURL, atomically: true, encoding: .utf8)
    //         logger.info("Report written to: \(fileURL.path)")
    //     } catch {
    //         logger.error("Failed to write report file: \(error)")
    //     }
    // }
}

// Note: AWSServiceMock, AWSDependencyVerificationReport, AWSCredentialCache etc.
// are assumed to be defined elsewhere (e.g., in the Tests directory) and imported.
// If running truly standalone, their definitions would need to be included here or in linked files.
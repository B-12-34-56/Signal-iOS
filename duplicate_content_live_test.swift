//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
import SignalServiceKit
import GRDB
import CryptoKit
import AWSCore
import AWSDynamoDB
@testable import Signal

/// This test script performs a comprehensive live test of the duplicate content detection system.
/// It validates hash storage in DynamoDB, attachment validation, and end-to-end workflows.
class DuplicateContentLiveTest {
    
    // MARK: - Test Configuration
    
    // Test data configuration
    private let testDataSizes = [10, 1024, 1024 * 100] // 10B, 1KB, 100KB
    private let testRuns = 3
    private let testDelay: TimeInterval = 1.0 // Delay between tests
    
    // Results tracking
    private var results = TestResults()
    private let resultsLock = NSLock()
    
    // Test dependencies
    private let signatureService = GlobalSignatureService.shared
    private let attachmentDownloadHook = AttachmentDownloadHook.shared
    private var databasePool: DatabasePool?
    
    // Logging
    private let logger = Logger(label: "org.signal.DuplicateContentLiveTest")
    
    // MARK: - Entry Point
    
    /// Main test entry point
    func runTests() async {
        printHeader("DUPLICATE CONTENT DETECTION SYSTEM LIVE TEST")
        
        await setupTestEnvironment()
        
        // Test 1: Test global hash storage and retrieval
        await testHashStorageAndRetrieval()
        
        // Test 2: Test attachment validation against global database
        await testAttachmentValidation()
        
        // Test 3: Test end-to-end workflow with attachments
        await testEndToEndWorkflow()
        
        generateReport()
    }
    
    // MARK: - Test Setup
    
    /// Sets up the test environment including database connections
    private func setupTestEnvironment() async {
        logger.info("Setting up test environment...")
        
        // Initialize AWS credentials
        do {
            AWSConfig.setupAWSCredentials()
            let credentialsValid = await AWSConfig.validateAWSCredentials()
            
            if credentialsValid {
                logger.info("✅ AWS credentials validated successfully.")
                results.awsCredentialsValid = true
            } else {
                logger.error("❌ AWS credentials validation failed.")
                results.awsCredentialsValid = false
            }
        } catch {
            logger.error("❌ Error initializing AWS: \(error.localizedDescription)")
            results.awsCredentialsValid = false
        }
        
        // Initialize database pool
        do {
            databasePool = try DatabasePool(path: ":memory:")
            attachmentDownloadHook.install(with: databasePool!)
            logger.info("✅ Database pool created and hook installed successfully")
            results.databaseSetupSuccessful = true
        } catch {
            logger.error("❌ Failed to create database pool: \(error.localizedDescription)")
            results.databaseSetupSuccessful = false
        }
    }
    
    // MARK: - Test Hash Storage and Retrieval
    
    /// Tests storing and retrieving hashes from DynamoDB
    private func testHashStorageAndRetrieval() async {
        printHeader("Test 1: Hash Storage and Retrieval")
        
        guard results.awsCredentialsValid else {
            logger.error("⚠️ Skipping hash storage test because AWS credentials are invalid.")
            return
        }
        
        // Generate random test hashes
        let testHashes = (0..<testRuns).map { _ in generateRandomHash() }
        
        for (index, hash) in testHashes.enumerated() {
            logger.info("Testing hash storage and retrieval (\(index + 1)/\(testRuns))")
            
            // Verify hash doesn't already exist
            let existsBefore = await signatureService.contains(hash)
            if existsBefore {
                logger.warning("⚠️ Test hash already exists in database. This is unexpected.")
            }
            
            // Test storing hash
            logger.info("Attempting to store hash: \(hash.prefix(8))...")
            let storeSuccess = await signatureService.store(hash)
            
            if storeSuccess {
                logger.info("✅ Hash stored successfully")
                trackResult(.hashStorageSuccess)
            } else {
                logger.error("❌ Failed to store hash")
                trackResult(.hashStorageFailure)
            }
            
            // Wait a moment for eventual consistency
            try? await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000))
            
            // Test retrieving hash
            logger.info("Attempting to verify hash exists: \(hash.prefix(8))...")
            let existsAfter = await signatureService.contains(hash)
            
            if existsAfter {
                logger.info("✅ Hash retrieved successfully")
                trackResult(.hashRetrievalSuccess)
            } else {
                logger.error("❌ Failed to retrieve hash")
                trackResult(.hashRetrievalFailure)
            }
            
            // Clean up test hash
            logger.info("Cleaning up test hash...")
            _ = await signatureService.delete(hash)
        }
    }
    
    // MARK: - Test Attachment Validation
    
    /// Tests the attachment validation flow
    private func testAttachmentValidation() async {
        printHeader("Test 2: Attachment Validation")
        
        guard results.databaseSetupSuccessful else {
            logger.error("⚠️ Skipping attachment validation test because database setup failed.")
            return
        }
        
        // Create test attachments of different sizes
        for size in testDataSizes {
            logger.info("Testing attachment validation with \(size) bytes")
            
            // Create mock data and attachment
            let attachmentData = generateRandomData(size: size)
            let attachment = createMockAttachment(data: attachmentData)
            
            // 1. Test with attachment not in blocked list
            logger.info("Testing attachment that should be allowed...")
            
            let validationResult = await attachmentDownloadHook.validateAttachment(attachment)
            
            if validationResult {
                logger.info("✅ Attachment correctly allowed")
                trackResult(.attachmentValidationSuccess)
            } else {
                logger.error("❌ Attachment incorrectly blocked")
                trackResult(.attachmentValidationFailure)
            }
            
            // 2. Test with attachment added to blocked list
            logger.info("Testing attachment that should be blocked...")
            
            let hash = computeHash(for: attachmentData)
            logger.info("Generated hash: \(hash.prefix(8))")
            
            // Add hash to blocked list
            await signatureService.store(hash)
            
            // Wait a moment for eventual consistency
            try? await Task.sleep(nanoseconds: UInt64(testDelay * 1_000_000_000))
            
            let blockedResult = await attachmentDownloadHook.validateAttachment(attachment)
            
            if !blockedResult {
                logger.info("✅ Attachment correctly blocked")
                trackResult(.blockedAttachmentDetectionSuccess)
            } else {
                logger.error("❌ Attachment incorrectly allowed")
                trackResult(.blockedAttachmentDetectionFailure)
            }
            
            // Clean up test hash
            _ = await signatureService.delete(hash)
        }
    }
    
    // MARK: - Test End-to-End Workflow
    
    /// Tests the complete end-to-end workflow of the duplicate content detection system
    private func testEndToEndWorkflow() async {
        printHeader("Test 3: End-to-End Workflow")
        
        // Mock message sending and receiving workflow
        let testAttachmentData = generateRandomData(size: 1024)
        let hash = computeHash(for: testAttachmentData)
        
        // Simulate message send with attachment
        logger.info("Simulating message send with attachment (hash: \(hash.prefix(8)))...")
        
        // Check if already blocked
        let preExistingBlock = await signatureService.contains(hash)
        if preExistingBlock {
            logger.warning("⚠️ Test hash already exists in database. This is unexpected.")
        }
        
        // Simulate successful message send
        let sendSuccess = await simulateMessageSend(testAttachmentData, hash: hash)
        if sendSuccess {
            logger.info("✅ Message send simulation successful")
            trackResult(.messageSendSuccess)
        } else {
            logger.error("❌ Message send simulation failed")
            trackResult(.messageSendFailure)
        }
        
        // Wait a moment for eventual consistency
        try? await Task.sleep(nanoseconds: UInt64(testDelay * 2_000_000_000))
        
        // Simulate message receive with the same attachment
        logger.info("Simulating message receive with same attachment...")
        let receiveResult = await simulateMessageReceive(testAttachmentData, hash: hash)
        if !receiveResult.allowed {
            logger.info("✅ Duplicate content correctly detected during receive")
            trackResult(.duplicateDetectionSuccess)
        } else {
            logger.error("❌ Duplicate content incorrectly allowed during receive")
            trackResult(.duplicateDetectionFailure) 
        }
        
        // Simulate message with modified content (should be allowed)
        logger.info("Simulating message receive with modified attachment...")
        var modifiedData = testAttachmentData
        modifiedData[0] = modifiedData[0] ^ 0xFF // Flip bits in first byte
        
        let modifiedResult = await simulateMessageReceive(modifiedData, hash: nil)
        if modifiedResult.allowed {
            logger.info("✅ Modified content correctly allowed during receive")
            trackResult(.modifiedContentSuccess)
        } else {
            logger.error("❌ Modified content incorrectly blocked during receive")
            trackResult(.modifiedContentFailure)
        }
        
        // Clean up test hash
        _ = await signatureService.delete(hash)
    }
    
    // MARK: - Simulation Helpers
    
    /// Simulates sending a message with an attachment
    /// - Returns: Success indicator
    private func simulateMessageSend(_ attachmentData: Data, hash: String) async -> Bool {
        // Store hash in global database (simulating successful send)
        return await signatureService.store(hash)
    }
    
    /// Simulates receiving a message with an attachment
    /// - Returns: Tuple containing allow status and hash
    private func simulateMessageReceive(_ attachmentData: Data, hash: String?) async -> (allowed: Bool, hash: String) {
        let attachment = createMockAttachment(data: attachmentData)
        let computedHash = hash ?? computeHash(for: attachmentData)
        let allowed = await attachmentDownloadHook.validateAttachment(attachment, hash: hash)
        return (allowed, computedHash)
    }
    
    // MARK: - Helper Methods
    
    /// Creates a mock attachment with the specified data
    private func createMockAttachment(data: Data) -> MockAttachment {
        let attachment = MockAttachment(uniqueId: UUID().uuidString, contentType: "image/jpeg")
        attachment.mockDataForDownload = data
        return attachment
    }
    
    /// Generates random data of the specified size
    private func generateRandomData(size: Int) -> Data {
        return Data((0..<size).map { _ in UInt8.random(in: 0...255) })
    }
    
    /// Generates a random hash string for testing
    private func generateRandomHash() -> String {
        return attachmentDownloadHook.generateTestingHash()
    }
    
    /// Computes a SHA-256 hash for the provided data
    private func computeHash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }
    
    /// Tracks a test result
    private func trackResult(_ result: TestResultType) {
        resultsLock.lock()
        defer { resultsLock.unlock() }
        
        results.testCounts[result, default: 0] += 1
    }
    
    /// Prints a section header
    private func printHeader(_ title: String) {
        let line = String(repeating: "=", count: title.count + 4)
        logger.info("\n\(line)")
        logger.info("  \(title)")
        logger.info("\(line)")
    }
    
    /// Generate and output a final report
    private func generateReport() {
        printHeader("TEST RESULTS")
        
        // Print configuration status
        logger.info("Configuration:")
        logger.info("  - AWS Credentials Valid: \(results.awsCredentialsValid ? "✅ Yes" : "❌ No")")
        logger.info("  - Database Setup Successful: \(results.databaseSetupSuccessful ? "✅ Yes" : "❌ No")")
        
        // Print test results
        logger.info("\nTest Results:")
        
        for (resultType, count) in results.testCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let status = count > 0 ? "✅" : "⚠️"
            logger.info("  \(status) \(resultType.description): \(count)")
        }
        
        // Calculate success rates
        let totalTests = results.testCounts.values.reduce(0, +)
        let successfulTests = results.testCounts.filter { $0.key.isSuccess }.values.reduce(0, +)
        let successRate = totalTests > 0 ? (Double(successfulTests) / Double(totalTests) * 100.0) : 0
        
        logger.info("\nSummary:")
        logger.info("  - Total Tests: \(totalTests)")
        logger.info("  - Successful Tests: \(successfulTests)")
        logger.info("  - Success Rate: \(String(format: "%.1f%%", successRate))")
        
        let overallResult = successRate >= 90.0 ? "✅ PASSED" : "❌ FAILED"
        logger.info("\nOverall Result: \(overallResult)")
    }
}

// MARK: - Support Types

/// Tracks the results of various tests
struct TestResults {
    var awsCredentialsValid = false
    var databaseSetupSuccessful = false
    var testCounts = [TestResultType: Int]()
}

/// Types of test results
enum TestResultType: Int, CustomStringConvertible {
    // Hash operations
    case hashStorageSuccess
    case hashStorageFailure
    case hashRetrievalSuccess
    case hashRetrievalFailure
    
    // Attachment validation
    case attachmentValidationSuccess
    case attachmentValidationFailure
    case blockedAttachmentDetectionSuccess
    case blockedAttachmentDetectionFailure
    
    // End-to-end workflow
    case messageSendSuccess
    case messageSendFailure
    case duplicateDetectionSuccess
    case duplicateDetectionFailure
    case modifiedContentSuccess
    case modifiedContentFailure
    
    var description: String {
        switch self {
        case .hashStorageSuccess: return "Hash Storage Success"
        case .hashStorageFailure: return "Hash Storage Failure"
        case .hashRetrievalSuccess: return "Hash Retrieval Success"
        case .hashRetrievalFailure: return "Hash Retrieval Failure"
        case .attachmentValidationSuccess: return "Attachment Validation Success"
        case .attachmentValidationFailure: return "Attachment Validation Failure"
        case .blockedAttachmentDetectionSuccess: return "Blocked Attachment Detection Success"
        case .blockedAttachmentDetectionFailure: return "Blocked Attachment Detection Failure"
        case .messageSendSuccess: return "Message Send Success"
        case .messageSendFailure: return "Message Send Failure"
        case .duplicateDetectionSuccess: return "Duplicate Detection Success"
        case .duplicateDetectionFailure: return "Duplicate Detection Failure"
        case .modifiedContentSuccess: return "Modified Content Success"
        case .modifiedContentFailure: return "Modified Content Failure"
        }
    }
    
    var isSuccess: Bool {
        switch self {
        case .hashStorageSuccess, .hashRetrievalSuccess,
             .attachmentValidationSuccess, .blockedAttachmentDetectionSuccess,
             .messageSendSuccess, .duplicateDetectionSuccess, .modifiedContentSuccess:
            return true
        default:
            return false
        }
    }
}

/// Mock implementation of TSAttachment for testing
class MockAttachment: TSAttachment {
    var mockDataForDownload: Data?
    var mockHashString: String?
    
    override func dataForDownload() throws -> Data {
        guard let mockDataForDownload = mockDataForDownload else {
            throw NSError(domain: "MockAttachmentError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No mock data available"])
        }
        return mockDataForDownload
    }
    
    override var aHashString: String? {
        get { return mockHashString }
        set { mockHashString = newValue }
    }
}

// MARK: - Script Runner

// Entry point for running the test script
let liveTest = DuplicateContentLiveTest()
Task {
    await liveTest.runTests()
    exit(0)
}

// Run the main run loop to keep the script alive until tests complete
RunLoop.main.run(until: .distantFuture)
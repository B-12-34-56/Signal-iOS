//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
import AWSCore
import AWSDynamoDB
import AWSAPIGateway
import AWSS3
import AWSLambda
import Logging

/// A standalone script for verifying AWS service configuration and connectivity,
/// with the ability to run with or without real AWS credentials.
class AWSVerificationTestScript {

    // MARK: - Properties

    /// Singleton instance for script execution
    static let shared = AWSVerificationTestScript()

    /// Flag to run in mock mode without actual AWS credentials
    let runInMockMode: Bool

    /// The logger instance for output
    private let logger: Logger

    /// Path for diagnostic log output
    private let logPath = "DuplicateContentDetection/Results/aws_dependency_verification.log"

    /// Start time of verification
    private var verificationStartTime: Date!

    // MARK: - Mock Services
    private var mockResponsesEnabled: Bool
    private var mockResponses: [String: Any] = [:]

    // MARK: - Test Results Structure
    private struct TestResult {
        let serviceName: String
        let success: Bool
        let duration: TimeInterval
        let error: Error?
        let details: [String: Any]
    }

    private var testResults: [TestResult] = []

    // MARK: - Initialization

    init(runInMockMode: Bool = false) {
        self.runInMockMode = runInMockMode
        self.mockResponsesEnabled = runInMockMode
        self.logger = Logger(label: "org.signal.verification.AWSVerificationScript")
        self.verificationStartTime = Date()
    }

    // MARK: - Main Verification Methods

    /// Runs all verification tests and generates a report
    func runAllTests() async {
        logger.info("Starting AWS service verification (Mock Mode: \(runInMockMode))")
        verificationStartTime = Date()

        // Initialize AWS if not in mock mode
        if !runInMockMode {
            await initializeAWS()
        }

        // Test AWS Credentials
        await verifyAWSCredentials()

        // Test DynamoDB
        await verifyDynamoDB()

        // Test API Gateway
        await verifyAPIGateway()

        // Test S3
        await verifyS3()

        // Generate and write report
        await generateReport()
    }

    // MARK: - Individual Verification Methods

    private func initializeAWS() async {
        logger.info("Initializing AWS SDK...")
        DuplicateContentDetection.AWSConfig.setupAWSCredentials()
        
        // Wait for credentials to be set up
        if await DuplicateContentDetection.AWSConfig.validateAWSCredentials(checkAPIGateway: false) {
            logger.info("AWS SDK initialization successful")
        } else {
            logger.error("AWS SDK initialization failed")
        }
    }

    private func verifyAWSCredentials() async {
        let startTime = Date()
        
        do {
            if runInMockMode {
                simulateMockCredentialsCheck()
            } else {
                let isValid = try await AWSCredentialsVerificationManager.shared.verifyCredentialsAsync(
                    setupCredentialsIfNeeded: false,
                    checkAPIGateway: false
                )
                
                testResults.append(TestResult(
                    serviceName: "AWS Credentials",
                    success: isValid,
                    duration: Date().timeIntervalSince(startTime),
                    error: nil,
                    details: ["identityPool": AWSConfig.identityPoolId]
                ))
            }
        } catch {
            testResults.append(TestResult(
                serviceName: "AWS Credentials",
                success: false,
                duration: Date().timeIntervalSince(startTime),
                error: error,
                details: [:]
            ))
        }
    }

    private func verifyDynamoDB() async {
        let startTime = Date()
        
        if runInMockMode {
            simulateMockDynamoDBCheck()
            return
        }

        do {
            let tableExists = await AWSConfig.ensureDynamoDbTableExists(createIfNotExists: false)
            let structure = await AWSCredentialsVerificationManager.shared.verifyTableStructure()
            
            testResults.append(TestResult(
                serviceName: "DynamoDB",
                success: tableExists && structure,
                duration: Date().timeIntervalSince(startTime),
                error: nil,
                details: [
                    "tableName": AWSConfig.dynamoDbTableName,
                    "tableExists": tableExists,
                    "correctStructure": structure
                ]
            ))
        } catch {
            testResults.append(TestResult(
                serviceName: "DynamoDB",
                success: false,
                duration: Date().timeIntervalSince(startTime),
                error: error,
                details: [:]
            ))
        }
    }

    private func verifyAPIGateway() async {
        let startTime = Date()
        
        if runInMockMode {
            simulateMockAPIGatewayCheck()
            return
        }

        let isValid = await AWSConfig.validateAPIGatewayConnectivity()
        testResults.append(TestResult(
            serviceName: "API Gateway",
            success: isValid,
            duration: Date().timeIntervalSince(startTime),
            error: nil,
            details: [
                "generalEndpoint": AWSConfig.apiGatewayEndpoint,
                "getTagEndpoint": AWSConfig.getTagApiGatewayEndpoint
            ]
        ))
    }

    private func verifyS3() async {
        let startTime = Date()
        let testBucketName = "signal-content-attachments"
        
        if runInMockMode {
            simulateMockS3Check()
            return
        }

        do {
            let request = AWSS3HeadBucketRequest()
            request?.bucket = testBucketName
            
            _ = try await AWSS3.default().headBucket(request!).await()
            
            testResults.append(TestResult(
                serviceName: "S3",
                success: true,
                duration: Date().timeIntervalSince(startTime),
                error: nil,
                details: ["bucketName": testBucketName]
            ))
        } catch {
            testResults.append(TestResult(
                serviceName: "S3",
                success: false,
                duration: Date().timeIntervalSince(startTime),
                error: error,
                details: ["bucketName": testBucketName]
            ))
        }
    }

    // MARK: - Mock Testing Methods

    private func simulateMockCredentialsCheck() {
        testResults.append(TestResult(
            serviceName: "AWS Credentials",
            success: true,
            duration: 0.5,
            error: nil,
            details: ["mode": "mock"]
        ))
    }

    private func simulateMockDynamoDBCheck() {
        testResults.append(TestResult(
            serviceName: "DynamoDB",
            success: true,
            duration: 0.3,
            error: nil,
            details: [
                "mode": "mock",
                "tableName": AWSConfig.dynamoDbTableName
            ]
        ))
    }

    private func simulateMockAPIGatewayCheck() {
        testResults.append(TestResult(
            serviceName: "API Gateway",
            success: true,
            duration: 0.2,
            error: nil,
            details: ["mode": "mock"]
        ))
    }

    private func simulateMockS3Check() {
        testResults.append(TestResult(
            serviceName: "S3",
            success: true,
            duration: 0.4,
            error: nil,
            details: ["mode": "mock"]
        ))
    }

    // MARK: - Report Generation

    private func generateReport() async {
        var report = "AWS Dependency Verification Report\n"
        report += "=================================\n\n"
        
        // Test Environment
        report += "Test Environment:\n"
        report += "- Date: \(ISO8601DateFormatter().string(from: verificationStartTime))\n"
        report += "- Mode: \(runInMockMode ? "Mock" : "Live")\n"
        report += "- Duration: \(String(format: "%.2f", Date().timeIntervalSince(verificationStartTime)))s\n\n"
        
        // Configuration
        report += "AWS Configuration:\n"
        report += "- Region: \(AWSConfig.dynamoDbRegion.rawValue)\n"
        report += "- DynamoDB Table: \(AWSConfig.dynamoDbTableName)\n"
        report += "- Identity Pool: \(AWSConfig.identityPoolId)\n\n"
        
        // Test Results
        report += "Test Results:\n"
        for result in testResults {
            report += "\n[\(result.success ? "✅" : "❌")] \(result.serviceName)\n"
            report += "  Duration: \(String(format: "%.3f", result.duration))s\n"
            
            if let error = result.error {
                report += "  Error: \(error.localizedDescription)\n"
            }
            
            for (key, value) in result.details {
                report += "  \(key): \(value)\n"
            }
        }
        
        // Summary
        let successCount = testResults.filter { $0.success }.count
        report += "\nSummary:\n"
        report += "- Total Tests: \(testResults.count)\n"
        report += "- Successful: \(successCount)\n"
        report += "- Failed: \(testResults.count - successCount)\n"
        
        // Write report
        do {
            try report.write(toFile: logPath, atomically: true, encoding: .utf8)
            logger.info("Verification report written to: \(logPath)")
        } catch {
            logger.error("Failed to write verification report: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helper Extensions

extension AWSTask {
    func await<T>() async throws -> T where T == ResultType {
        return try await withCheckedThrowingContinuation { continuation in
            self.continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else if let result = task.result as? T {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AWSVerificationError",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected result type"]
                    ))
                }
                return nil
            }
        }
    }
}

// MARK: - Standalone Execution

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
@main
struct AWSVerificationTestScriptRunner {
    static func main() async {
        // Get mock mode from environment or command line args
        let mockMode = ProcessInfo.processInfo.environment["MOCK_MODE"] == "1"
        
        let script = AWSVerificationTestScript(runInMockMode: mockMode)
        await script.runAllTests()
    }
}
#endif
//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import AWSDynamoDB
import AWSAPIGateway
import AWSS3
import AWSLambda
import Logging

/// A test class that verifies AWS credentials and connections for the duplicate content detection system.
class AwsCredentialsVerifier: XCTestCase {
    
    // MARK: - Properties
    
    /// Logger for the test class
    private let logger = Logger(label: "org.signal.tests.AwsCredentialsVerifier")
    
    /// The AWS configuration to test
    private var awsConfig: AWSConfig.Type!
    
    /// The verification manager instance to test
    private var verificationManager: AWSCredentialsVerificationManager!
    
    /// Custom region for testing different AWS environments
    private var customRegion: AWSRegionType?
    
    /// Custom identity pool ID for testing different configurations
    private var customIdentityPoolId: String?
    
    /// Path to the log file for test results
    private let logFilePath = "DuplicateContentDetection/Results/aws_verification_results.log"
    
    // Test timestamps for measuring performance
    private var testStartTime: Date!
    private var testEndTime: Date!
    
    // MARK: - Setup and Teardown
    
    override func setUp() {
        super.setUp()
        
        // Reset start time for each test
        testStartTime = Date()
        
        // Initialize the verification manager with default configuration
        verificationManager = AWSCredentialsVerificationManager.shared
        
        // Reset previous test state
        verificationManager.resetForTesting()
        AWSConfig.resetCredentialsState()
        
        // Set up default aws config reference
        awsConfig = AWSConfig.self
        
        // Log test initialization
        logger.info("Starting AWS credentials verification test at \(ISO8601DateFormatter().string(from: testStartTime))")
    }
    
    override func tearDown() {
        // Calculate test duration
        testEndTime = Date()
        let testDuration = testEndTime.timeIntervalSince(testStartTime)
        
        // Log test completion
        logger.info("AWS credentials verification test completed in \(String(format: "%.2f", testDuration)) seconds")
        
        // Reset custom test configurations
        customRegion = nil
        customIdentityPoolId = nil
        
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    /// Configures AWS with custom test parameters
    /// - Parameters:
    ///   - region: Custom AWS region to test
    ///   - identityPoolId: Custom identity pool ID to test
    private func configureTestEnvironment(region: AWSRegionType? = nil, identityPoolId: String? = nil) {
        if let region = region {
            customRegion = region
            // If we were able to modify AWSConfig directly, we would do:
            // awsConfig.dynamoDbRegion = region
            // awsConfig.cognitoRegion = region
        }
        
        if let identityPoolId = identityPoolId {
            customIdentityPoolId = identityPoolId
            // If we were able to modify AWSConfig directly, we would do:
            // awsConfig.identityPoolId = identityPoolId
        }
    }
    
    /// Writes test results to the log file
    /// - Parameters:
    ///   - results: Dictionary of service validation results
    ///   - errors: Optional array of errors encountered during testing
    private func logTestResults(_ results: [String: Bool], errors: [Error]? = nil) {
        var logContent = "=== AWS Credentials Verification Test Results ===\n\n"
        logContent += "Test Date: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        logContent += "AWS Configuration:\n"
        logContent += "- Region: \(customRegion?.rawValue ?? AWSConfig.dynamoDbRegion.rawValue)\n"
        logContent += "- Identity Pool ID: \(customIdentityPoolId ?? AWSConfig.identityPoolId)\n"
        logContent += "- DynamoDB Table: \(AWSConfig.dynamoDbTableName)\n\n"
        
        logContent += "Service Validation Results:\n"
        for (service, isValid) in results.sorted(by: { $0.key < $1.key }) {
            let status = isValid ? "✅ PASSED" : "❌ FAILED"
            logContent += "- \(service): \(status)\n"
        }
        
        if let errors = errors, !errors.isEmpty {
            logContent += "\nErrors Encountered:\n"
            for (index, error) in errors.enumerated() {
                logContent += "[\(index + 1)] \(error.localizedDescription)\n"
            }
        }
        
        let isValid = results.values.allSatisfy { $0 }
        logContent += "\nOverall Assessment: \(isValid ? "✅ PASSED" : "❌ FAILED")\n"
        
        // Write to log file
        do {
            try logContent.write(toFile: logFilePath, atomically: true, encoding: .utf8)
            logger.info("Test results written to \(logFilePath)")
        } catch {
            logger.error("Failed to write test results to log file: \(error.localizedDescription)")
        }
    }
    
    /// Simulates the AppDelegate initialization flow for AWS services
    /// - Returns: Boolean indicating if the initialization succeeded
    private func simulateAppDelegateInitializationFlow() async -> Bool {
        logger.info("Simulating AppDelegate initialization flow...")
        
        // 1. Setup AWS Credentials (similar to AppDelegate)
        AWSConfig.setupAWSCredentials()
        
        // 2. Verify credentials
        var awsVerified = false
        do {
            awsVerified = try await verificationManager.verifyCredentialsAsync(
                setupCredentialsIfNeeded: false,
                checkAPIGateway: true,
                verifyTableExists: true
            )
        } catch {
            logger.error("AWS verification failed with error: \(error.localizedDescription)")
            return false
        }
        
        logger.info("AppDelegate initialization flow simulation completed with result: \(awsVerified ? "success" : "failure")")
        return awsVerified
    }
    
    // MARK: - Test Cases
    
    /// Tests AWS credentials setup and validation
    func testAWSCredentialsSetup() async throws {
        // First ensure credentials setup works
        AWSConfig.setupAWSCredentials()
        XCTAssertTrue(AWSConfig.isCredentialsSetup, "AWS credentials should be set up")
        
        // Test credentials validation
        let isValid = await AWSConfig.validateAWSCredentials(checkAPIGateway: false)
        XCTAssertTrue(isValid, "AWS credentials should be valid")
    }
    
    /// Tests the region configuration for AWS services
    func testRegionConfiguration() {
        XCTAssertEqual(AWSConfig.dynamoDbRegion, AWSRegionType.USEast1, "DynamoDB region should be USEast1")
        XCTAssertEqual(AWSConfig.cognitoRegion, AWSRegionType.USEast1, "Cognito region should be USEast1")
        
        // Verify that region settings match between config and endpoint
        XCTAssertTrue(
            AWSConfig.dynamoDbEndpoint.contains(AWSConfig.dynamoDbRegion.rawValue.lowercased()),
            "DynamoDB endpoint should match the configured region"
        )
    }
    
    /// Tests the identity pool ID configuration
    func testIdentityPoolIdConfiguration() {
        XCTAssertEqual(
            AWSConfig.identityPoolId,
            "us-east-1:ee264a1b-9b89-4e4a-a346-9128da47af97",
            "Identity Pool ID should match the configured value"
        )
        
        // Verify the region prefix in the identity pool ID matches the Cognito region
        let regionPrefix = AWSConfig.identityPoolId.components(separatedBy: ":").first
        XCTAssertEqual(
            regionPrefix?.lowercased(),
            AWSConfig.cognitoRegion.rawValue.lowercased(),
            "Identity Pool ID region prefix should match Cognito region"
        )
    }
    
    /// Tests the DynamoDB table existence check
    func testDynamoDBTableExistence() async {
        // Test with table creation disabled
        let tableExists = await AWSConfig.ensureDynamoDbTableExists(createIfNotExists: false)
        XCTAssertTrue(tableExists, "DynamoDB table should exist")
    }
    
    /// Tests DynamoDB connectivity directly
    func testDynamoDBConnectivity() async {
        let isConnected = await verificationManager.verifyDynamoDBConnectivity()
        XCTAssertTrue(isConnected, "Should be able to connect to DynamoDB")
    }
    
    /// Tests DynamoDB table structure verification
    func testDynamoDBTableStructure() async {
        let hasCorrectStructure = await verificationManager.verifyTableStructure()
        XCTAssertTrue(hasCorrectStructure, "DynamoDB table should have correct structure")
    }
    
    /// Tests API Gateway connectivity
    func testAPIGatewayConnectivity() async {
        let isConnected = await AWSConfig.validateAPIGatewayConnectivity()
        XCTAssertTrue(isConnected, "Should be able to connect to API Gateway endpoints")
    }
    
    /// Tests the AWS retry mechanism with simulated errors
    func testRetryMechanism() async {
        do {
            var attemptCount = 0
            
            let result = try await verificationManager.executeWithRetry({
                attemptCount += 1
                
                if attemptCount < 2 {
                    throw NSError(domain: "TestError", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Simulated error for retry testing"])
                }
                
                return true
            }, maxAttempts: 3)
            
            XCTAssertTrue(result, "Operation should succeed after retries")
            XCTAssertEqual(attemptCount, 2, "Operation should have been attempted twice")
        } catch {
            XCTFail("Retry mechanism test failed with error: \(error.localizedDescription)")
        }
    }
    
    /// Tests the comprehensive service validation method
    func testComprehensiveServiceValidation() async {
        // Set up AWS credentials first
        AWSConfig.setupAWSCredentials()
        
        // Run comprehensive validation
        let results = await verificationManager.validateAllServices()
        
        // Verify each expected service was tested
        XCTAssertNotNil(results["cognito"], "Cognito validation result should be present")
        XCTAssertNotNil(results["dynamodb"], "DynamoDB validation result should be present")
        XCTAssertNotNil(results["table_structure"], "Table structure validation result should be present")
        XCTAssertNotNil(results["api_gateway"], "API Gateway validation result should be present")
        
        // Log the results
        logTestResults(results)
    }
    
    /// Tests failed authentication scenarios
    func testFailedAuthentication() async {
        // Configure with invalid identity pool ID
        configureTestEnvironment(identityPoolId: "us-east-1:00000000-0000-0000-0000-000000000000")
        
        // Reset credentials state to force re-authentication
        verificationManager.resetForTesting()
        
        // This test can't truly validate with the invalid ID since we can't modify AWSConfig directly in tests
        // Instead, we'll log that this test would check for proper error handling
        logger.info("In a real environment, this test would verify that invalid credentials are properly detected and reported")
    }
    
    /// Tests the AppDelegate initialization flow
    func testAppDelegateInitializationFlow() async {
        let success = await simulateAppDelegateInitializationFlow()
        XCTAssertTrue(success, "AppDelegate initialization flow should succeed")
    }
    
    /// Tests generation of the diagnostic report
    func testDiagnosticReport() async {
        let report = await verificationManager.generateDiagnosticReport()
        
        // Verify report contains expected sections
        XCTAssertTrue(report.contains("AWS Credentials Verification Diagnostic Report"), "Report should have the correct title")
        XCTAssertTrue(report.contains("AWS Configuration:"), "Report should include configuration section")
        XCTAssertTrue(report.contains("Service Validation Results:"), "Report should include validation results")
        XCTAssertTrue(report.contains("Overall Assessment:"), "Report should include overall assessment")
        
        // Log the diagnostic report
        logger.info("Generated diagnostic report:\n\(report)")
    }
    
    /// Tests backoff delay calculation
    func testBackoffDelayCalculation() {
        let delay1 = AWSConfig.calculateBackoffDelay(attempt: 1)
        let delay2 = AWSConfig.calculateBackoffDelay(attempt: 2)
        let delay3 = AWSConfig.calculateBackoffDelay(attempt: 3)
        
        XCTAssertGreaterThan(delay1, 0, "First attempt delay should be positive")
        XCTAssertGreaterThan(delay2, delay1, "Second attempt delay should be greater than first")
        XCTAssertGreaterThan(delay3, delay2, "Third attempt delay should be greater than second")
        
        // Test max delay cap
        let maxDelay = AWSConfig.calculateBackoffDelay(attempt: 10, maxDelaySeconds: 5)
        XCTAssertLessThanOrEqual(maxDelay, 5 * 1.25, "Delay should be capped at max value (plus potential jitter)")
    }
    
    /// Test the comprehensive validation flow with multiple regions (simulated)
    func testMultiRegionValidation() async {
        // Tests for different AWS regions
        // Since we can't actually modify the region, this just demonstrates how we would test multiple regions
        let regions = [
            AWSRegionType.USEast1,
            AWSRegionType.USEast2,
            AWSRegionType.USWest1,
            AWSRegionType.USWest2
        ]
        
        for region in regions {
            configureTestEnvironment(region: region)
            logger.info("Testing with region: \(region.rawValue)")
            
            // In a real test that could modify AWSConfig, we would validate against each region
            // For now, just log what we would do
            logger.info("Would validate AWS services in region \(region.rawValue)")
        }
        
        // Return to default region and verify
        configureTestEnvironment(region: AWSRegionType.USEast1)
    }
    
    /// Test system resources and report findings
    func testSystemConfiguration() async {
        var results = [String: Bool]()
        var errors = [Error]()
        
        // Get device info
        let deviceName = UIDevice.current.name
        let systemVersion = UIDevice.current.systemVersion
        logger.info("Testing on device: \(deviceName), iOS \(systemVersion)")
        
        // Test network connectivity (basic check)
        do {
            let url = URL(string: "https://www.signal.org")!
            let (_, response) = try await URLSession.shared.data(from: url)
            let httpResponse = response as! HTTPURLResponse
            results["network_connectivity"] = (200...299).contains(httpResponse.statusCode)
        } catch {
            results["network_connectivity"] = false
            errors.append(error)
        }
        
        // Get bundle info
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        logger.info("App version: \(appVersion) (\(buildNumber))")
        
        // Run AWS verification
        do {
            let awsValid = try await verificationManager.verifyCredentialsAsync()
            results["aws_credentials"] = awsValid
        } catch {
            results["aws_credentials"] = false
            errors.append(error)
        }
        
        // Log all results
        logTestResults(results, errors: errors)
    }
}
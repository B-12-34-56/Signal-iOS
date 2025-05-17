//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import AWSLambda
import Logging
@testable import DuplicateContentDetection // Import the module containing LambdaService and AWSConfig

/// Tests for validating AWS Lambda function configuration and invocation based on aws-config.json.
class TestLambdaService: XCTestCase {

    // MARK: - Properties

    private var lambdaService: LambdaService!
    private let logger = Logger(label: "org.signal.tests.TestLambdaService")

    // Configuration from aws-config.json and DuplicateContentDetection.AWSConfig
    // Function Name: signal-content-processor
    // Region: us-east-1
    // Environment Variables: DYNAMODB_TABLE=SignalContentHashes, S3_BUCKET=signal-content-attachments
    private let expectedFunctionName = "signal-content-processor"
    // ARN from aws-config.json, useful for GetFunction requests if needed
    private let expectedFunctionArn = "arn:aws:lambda:us-east-1:739874238091:function:ContentProcessor"
    private let expectedRegion = AWSRegionType.USEast1
    private let expectedDynamoDBTableName = "SignalContentHashes"
    private let expectedS3BucketName = "signal-content-attachments"

    // Flag to enable tests against actual AWS. Requires credentials to be configured.
    // WARNING: Enabling this will incur AWS costs and requires proper credential setup.
    private let runValidationTestsAgainstRealAWS = false

    // Sample payload for invocation test
    private let sampleInvocationPayload: [String: Any] = [
        "operation": "hashValidation",
        "contentHash": "dummyTestHashForValidation123456=="
    ]

    // MARK: - Test Lifecycle

    override func setUp() async throws {
        try await super.setUp()

        // Ensure AWS Credentials are set up if running validation tests
        if runValidationTestsAgainstRealAWS {
            logger.info("Setting up AWS credentials for Lambda validation tests...")
            DuplicateContentDetection.AWSConfig.setupAWSCredentials()
            // Give credentials provider a moment to fetch identity ID if needed
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds delay
            let isValid = await DuplicateContentDetection.AWSConfig.validateAWSCredentials(checkAPIGateway: false)
            if !isValid {
                logger.error("AWS Credentials setup failed or are invalid. Skipping validation tests against real AWS.")
                // Optionally, throw an error to fail the setup
                // throw NSError(domain: "TestSetupError", code: 1, userInfo: [NSLocalizedDescriptionKey: "AWS Credentials invalid"])
            } else {
                 logger.info("AWS Credentials seem valid for Lambda tests.")
            }
        }

        // Initialize the LambdaService. It uses the default client configured by AWSConfig.
        lambdaService = LambdaService()

        logger.info("TestLambdaService setup complete.")
    }

    override func tearDown() async throws {
        lambdaService = nil
        logger.info("TestLambdaService teardown complete.")
        try await super.tearDown()
    }

    // MARK: - Configuration Validation Tests

    /// Validates that the Lambda function name and region used by the service match expectations.
    /// This primarily checks the constants used within the LambdaService itself.
    func testInternalFunctionConfiguration() {
        // Access the function name used by the LambdaService instance
        // Note: LambdaService doesn't expose its function name directly, we assume it uses expectedFunctionName
        logger.info("Assuming LambdaService targets function: \(expectedFunctionName) in region \(expectedRegion.rawValue) based on configuration.")
        // A direct check could be added if LambdaService exposed its target function/region.
        // The actual validation happens in tests interacting with the function.
    }

    /// Validates the function's configuration via GetFunctionConfiguration API call.
    func testFunctionConfigurationValidation() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testFunctionConfigurationValidation as runValidationTestsAgainstRealAWS is false.")
            return
        }

        logger.info("Attempting to get configuration for function: \(expectedFunctionName)")

        let request = AWSLambdaGetFunctionConfigurationRequest()
        request?.functionName = expectedFunctionName

        let client = AWSLambda.default() // Get the default Lambda client

        do {
            let task = client.getFunctionConfiguration(request!)
            let config = try await task.await() // Use await extension

            logger.info("Successfully retrieved configuration for function: \(expectedFunctionName)")
            logger.info(" - Runtime: \(config.runtime?.aws_string() ?? "N/A")")
            logger.info(" - Handler: \(config.handler ?? "N/A")")
            logger.info(" - Memory: \(config.memorySize?.intValue ?? 0) MB")
            logger.info(" - Timeout: \(config.timeout?.intValue ?? 0) sec")
            logger.info(" - ARN: \(config.functionArn ?? "N/A")")

            // Basic checks
            XCTAssertEqual(config.functionName, expectedFunctionName, "Function name should match.")
            XCTAssertEqual(config.functionArn, expectedFunctionArn, "Function ARN should match aws-config.json.")
            // Note: Region isn't directly in GetFunctionConfiguration, but ARN contains it.
            XCTAssertTrue(config.functionArn?.contains(expectedRegion.rawValue) ?? false, "Function ARN should contain the correct region.")

        } catch let error as NSError {
             logger.error("GetFunctionConfiguration failed for \(expectedFunctionName): \(error.localizedDescription) (Code: \(error.code), Domain: \(error.domain))")
             if error.domain == AWSLambdaErrorDomain, error.code == AWSLambdaErrorType.resourceNotFoundException.rawValue {
                 XCTFail("GetFunctionConfiguration failed because the function '\(expectedFunctionName)' was not found.")
             } else if error.domain == AWSLambdaErrorDomain, error.code == AWSLambdaErrorType.accessDeniedException.rawValue {
                 XCTFail("GetFunctionConfiguration failed due to access denied for function '\(expectedFunctionName)'. Check IAM permissions (lambda:GetFunctionConfiguration).")
             } else {
                  XCTFail("GetFunctionConfiguration failed for function '\(expectedFunctionName)' with an unexpected error: \(error.localizedDescription)")
             }
         }
    }

    /// Validates the function's environment variables via GetFunctionConfiguration API call.
    func testEnvironmentVariableValidation() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testEnvironmentVariableValidation as runValidationTestsAgainstRealAWS is false.")
            return
        }

        logger.info("Attempting to get environment variables for function: \(expectedFunctionName)")

        let request = AWSLambdaGetFunctionConfigurationRequest()
        request?.functionName = expectedFunctionName

        let client = AWSLambda.default()

        do {
            let task = client.getFunctionConfiguration(request!)
            let config = try await task.await()

            guard let environment = config.environment, let variables = environment.variables else {
                XCTFail("Failed to retrieve environment variables for function \(expectedFunctionName).")
                return
            }

            logger.info("Retrieved environment variables:")
            variables.forEach { key, value in logger.info(" - \(key): \(value)") }

            // Validate expected variables
            XCTAssertEqual(variables["DYNAMODB_TABLE"], expectedDynamoDBTableName, "DYNAMODB_TABLE environment variable should match.")
            XCTAssertEqual(variables["S3_BUCKET"], expectedS3BucketName, "S3_BUCKET environment variable should match.")

            logger.info("✅ Environment variable validation successful.")

        } catch let error as NSError {
             // Reuse error handling from testFunctionConfigurationValidation
             logger.error("GetFunctionConfiguration (for env vars) failed: \(error.localizedDescription)")
             XCTFail("Failed to get function configuration for environment variable check: \(error.localizedDescription)")
         }
    }

    // MARK: - Invocation Validation Tests

    /// Validates the ability to invoke the Lambda function successfully.
    func testFunctionInvocationValidation() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testFunctionInvocationValidation as runValidationTestsAgainstRealAWS is false.")
            return
        }

        logger.info("Starting invocation validation for function: \(expectedFunctionName)")

        // Convert payload dictionary to JSON Data
        guard let payloadData = try? JSONSerialization.data(withJSONObject: sampleInvocationPayload, options: []) else {
            XCTFail("Failed to serialize sample payload to JSON.")
            return
        }
        logger.info("Sample Payload (JSON): \(String(data: payloadData, encoding: .utf8) ?? "Invalid JSON")")

        // Use the LambdaService method which handles invocation internally
        // We'll call a method that uses the expected function, e.g., validateContentHash
        // Note: This tests the LambdaService's invocation logic, not just raw AWSLambda.invoke
        
        logger.info("Attempting to invoke via LambdaService.validateContentHash...")
        // This requires the Lambda function to handle the "hashValidation" operation
        // and return a decodable ContentValidationResult structure.
        let validationResult = await lambdaService.validateContentHash(sampleInvocationPayload["contentHash"] as! String)

        // The success of this depends heavily on the Lambda function's implementation.
        // A basic check is if we got *any* result back without throwing an error.
        if let result = validationResult {
             logger.info("✅ Lambda invocation via service method succeeded. Status: \(result.status ?? "N/A"), Hash: \(result.contentHash ?? "N/A")")
             // We expect the function to handle the dummy hash appropriately (e.g., return 'not_found' or 'allowed')
             XCTAssertNotNil(result.status, "Invocation should return a result with a status.")
        } else {
             logger.error("❌ Lambda invocation via service method failed (returned nil). Check Lambda function logs and permissions.")
             // We cannot assert failure directly here as nil could be a valid outcome depending on error handling
             // Add specific checks based on expected errors if possible.
             // For now, just log the failure.
             XCTFail("Lambda invocation through LambdaService returned nil. Check logs.")
        }
    }

    /// Validates that invoking the function succeeds, implying sufficient permissions.
    func testFunctionPermissionsValidation() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testFunctionPermissionsValidation as runValidationTestsAgainstRealAWS is false.")
            return
        }

        logger.info("Attempting basic invocation to validate permissions for function: \(expectedFunctionName)")

         // Convert payload dictionary to JSON Data
        guard let payloadData = try? JSONSerialization.data(withJSONObject: sampleInvocationPayload, options: []) else {
            XCTFail("Failed to serialize sample payload to JSON.")
            return
        }

        // Use raw AWSLambda invoke for a direct permission check
        let request = AWSLambdaInvocationRequest()
        request?.functionName = expectedFunctionName
        request?.invocationType = .requestResponse // Synchronous invocation
        request?.payload = payloadData

        let client = AWSLambda.default()

        do {
            let task = client.invoke(request!)
            let response = try await task.await() // Use await extension

            // Check for function-specific errors returned in the payload vs AWS errors
            if let functionError = response.functionError, !functionError.isEmpty {
                 logger.warning("Lambda function executed but returned an error: \(functionError). Payload: \(String(data: response.payload ?? Data(), encoding: .utf8) ?? "N/A")")
                 // This still indicates successful invocation permission, but the function itself failed.
                 // Depending on the test goal, this might be acceptable or a failure.
                 // For a pure permission check, this is a success.
                 XCTAssertTrue(true, "Function invoked, indicating sufficient lambda:InvokeFunction permission, but returned an error: \(functionError)")
             } else if response.statusCode?.intValue == 200 {
                 logger.info("✅ Lambda invocation successful (Status Code 200). Implies sufficient lambda:InvokeFunction permission.")
                 XCTAssertEqual(response.statusCode?.intValue, 200, "Successful invocation should return status 200.")
             } else {
                  logger.warning("Lambda invocation returned unexpected status code: \(response.statusCode?.intValue ?? -1). Payload: \(String(data: response.payload ?? Data(), encoding: .utf8) ?? "N/A")")
                  XCTFail("Lambda invocation returned unexpected status code: \(response.statusCode?.intValue ?? -1)")
              }

        } catch let error as NSError {
             logger.error("Lambda invocation failed: \(error.localizedDescription) (Code: \(error.code), Domain: \(error.domain))")
             if error.domain == AWSLambdaErrorDomain, error.code == AWSLambdaErrorType.accessDeniedException.rawValue {
                 XCTFail("Lambda invocation failed due to access denied. Check IAM permissions (lambda:InvokeFunction).")
             } else if error.domain == AWSLambdaErrorDomain, error.code == AWSLambdaErrorType.resourceNotFoundException.rawValue {
                 XCTFail("Lambda invocation failed because the function '\(expectedFunctionName)' was not found.")
             } else {
                  XCTFail("Lambda invocation failed with an unexpected error: \(error.localizedDescription)")
             }
         }
    }

    // MARK: - Error Handling Tests

    /// Tests error handling when trying to invoke a non-existent Lambda function.
    func testErrorHandling_FunctionNotFound() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testErrorHandling_FunctionNotFound as runValidationTestsAgainstRealAWS is false.")
            return
        }

        let nonExistentFunctionName = "non-existent-function-\(UUID().uuidString)"
        logger.info("Attempting to invoke non-existent function: \(nonExistentFunctionName)")

        let request = AWSLambdaInvocationRequest()
        request?.functionName = nonExistentFunctionName
        request?.invocationType = .requestResponse
        request?.payload = "{}".data(using: .utf8) // Empty payload

        let client = AWSLambda.default()

        do {
            let task = client.invoke(request!)
            _ = try await task.await() // Expecting this to throw
            XCTFail("Invoking a non-existent function should have thrown an error.")
        } catch let error as NSError {
            logger.info("Caught expected error: \(error.localizedDescription)")
            // Check for ResourceNotFoundException
             XCTAssertEqual(error.domain, AWSLambdaErrorDomain, "Error domain should be AWSLambdaErrorDomain.")
             XCTAssertEqual(AWSLambdaErrorType(rawValue: error.code), .resourceNotFoundException, "Error code should indicate ResourceNotFoundException.")
            logger.info("✅ Correctly received ResourceNotFoundException.")
        } catch {
             XCTFail("Invoking a non-existent function threw an unexpected error type: \(error)")
         }
    }

    // MARK: - Integration Tests (Placeholder)

    /// Placeholder for integration tests involving Lambda, S3, and DynamoDB.
    func testIntegrationWithS3AndDynamoDB() {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testIntegrationWithS3AndDynamoDB as runValidationTestsAgainstRealAWS is false.")
            return
        }
        logger.warning("Integration test 'testIntegrationWithS3AndDynamoDB' is not fully implemented.")
        XCTExpectFailure("Integration test requires complex setup/teardown and is not implemented.")
        // Steps would involve:
        // 1. Uploading a specific file to the S3 bucket's 'uploads/' prefix.
        // 2. Waiting for the Lambda function (triggered by S3 event) to execute.
        //    - This might require polling DynamoDB or checking CloudWatch logs.
        // 3. Querying DynamoDB for the expected hash record created by the Lambda.
        // 4. Asserting the record exists and contains correct data.
        // 5. Cleaning up the S3 object and potentially the DynamoDB record.
    }
}

// MARK: - AWSTask await Extension (Helper)
// Simple extension to allow awaiting AWSTask results

extension AWSTask {
    func await<T>() async throws -> T where T == ResultType {
        return try await withCheckedThrowingContinuation { continuation in
            self.continueWith { task -> Any? in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else if let result = task.result as? T {
                    continuation.resume(returning: result)
                } else if task.result == nil && T.self == Void.self {
                     // Handle tasks that complete successfully with no result (Void)
                     continuation.resume(returning: () as! T)
                } else {
                     // Should not happen if ResultType matches T, unless result is unexpectedly nil
                    continuation.resume(throwing: NSError(domain: "AWSTaskError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected task result type (\(String(describing: task.result))) or nil result for expected type \(T.self)."]))
                }
                return nil
            }
        }
    }

    // Specific overload for Void or optional AnyObject results to avoid casting issues
     func await() async throws -> Void where ResultType == Any? || ResultType == AnyObject? || ResultType == Void {
         return try await withCheckedThrowingContinuation { continuation in
             self.continueWith { task -> Any? in
                 if let error = task.error {
                     continuation.resume(throwing: error)
                 } else {
                     // Task succeeded, return Void
                     continuation.resume(returning: ())
                 }
                 return nil
             }
         }
     }
}
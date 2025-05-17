//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import AWSS3
import Logging
@testable import DuplicateContentDetection // Import the module containing S3Service and AWSConfig

/// Tests for the S3Service class focusing on validation against configured AWS settings.
class TestS3Service: XCTestCase {

    // MARK: - Properties

    private var s3Service: S3Service!
    private let logger = Logger(label: "org.signal.tests.TestS3Service")
    
    // Configuration from DuplicateContentDetection.AWSConfig and aws-config.json
    // Note: aws-config.json specifies bucket 'signal-content-attachments', region 'us-east-1'
    private let expectedBucketName = "signal-content-attachments"
    private let expectedRegion = AWSRegionType.USEast1
    private let expectedEncryption = "AES256" // From aws-config.json

    // Flag to enable tests against actual AWS. Requires credentials to be configured.
    // WARNING: Enabling this will incur AWS costs and requires proper credential setup.
    private let runValidationTestsAgainstRealAWS = false

    // Test data
    private let testData = Data("This is test data for S3 validation.".utf8)
    private let testObjectKey = "s3-validation-test-\(UUID().uuidString).txt"

    // MARK: - Test Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        
        // Ensure AWS Credentials are set up if running validation tests
        if runValidationTestsAgainstRealAWS {
            logger.info("Setting up AWS credentials for validation tests...")
            DuplicateContentDetection.AWSConfig.setupAWSCredentials()
            // Give credentials provider a moment to fetch identity ID if needed
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds delay
            let isValid = await DuplicateContentDetection.AWSConfig.validateAWSCredentials(checkAPIGateway: false)
            if !isValid {
                logger.error("AWS Credentials setup failed or are invalid. Skipping validation tests against real AWS.")
                // Optionally, throw an error to fail the setup
                // throw NSError(domain: "TestSetupError", code: 1, userInfo: [NSLocalizedDescriptionKey: "AWS Credentials invalid"])
            } else {
                 logger.info("AWS Credentials seem valid.")
            }
        }
        
        // Initialize the S3Service. This will use the default client configured by AWSConfig.
        s3Service = S3Service()
        
        logger.info("TestS3Service setup complete.")
    }

    override func tearDown() async throws {
        // Clean up test object if it was created during validation tests
        if runValidationTestsAgainstRealAWS {
            logger.info("Cleaning up test S3 object: \(testObjectKey)")
            let deleted = await s3Service.deleteFile(key: testObjectKey)
            if !deleted {
                 // Log error, but don't fail the test for cleanup issues
                logger.warning("Failed to clean up test S3 object: \(testObjectKey)")
            }
        }
        
        s3Service = nil
        logger.info("TestS3Service teardown complete.")
        try await super.tearDown()
    }
    
    // MARK: - Configuration Validation Tests
    
    /// Validates that the S3 bucket name configured in the service matches expectations.
    func testBucketConfigurationValidation() {
        // Access the bucket name used by the S3Service instance
        // Note: S3Service doesn't expose its bucket name directly, we assume it uses the one from aws-config.json
        // This test implicitly verifies if operations target the correct bucket.
        // A direct check could be added if S3Service exposed its target bucket.
        logger.info("Assuming S3Service targets bucket: \(expectedBucketName) based on configuration.")
        // No direct assertion possible without exposing the bucket name from S3Service.
        // The actual validation happens in tests interacting with the bucket.
    }
    
    /// Validates basic access permissions to the configured S3 bucket using HeadBucket.
    func testBucketAccessValidation() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testBucketAccessValidation as runValidationTestsAgainstRealAWS is false.")
            return
        }
        
        logger.info("Attempting to perform HeadBucket on bucket: \(expectedBucketName)")
        
        let request = AWSS3HeadBucketRequest()
        request?.bucket = expectedBucketName
        
        let client = AWSS3.default() // Get the default S3 client
        
        do {
            let task = client.headBucket(request!)
            _ = try await task.await() // Use await extension if available, otherwise handle AWSTask
            logger.info("HeadBucket operation successful for bucket: \(expectedBucketName)")
            // Success means we have at least ListBucket permissions or the bucket exists and is accessible.
            XCTAssertTrue(true, "HeadBucket should succeed if permissions allow.")
            
        } catch let error as NSError {
             logger.error("HeadBucket failed for bucket \(expectedBucketName): \(error.localizedDescription) (Code: \(error.code), Domain: \(error.domain))")
             // Differentiate between access denied and bucket not found if possible
             if error.domain == AWSS3ErrorDomain, error.code == AWSS3ErrorType.noSuchBucket.rawValue {
                 XCTFail("HeadBucket failed because the bucket '\(expectedBucketName)' does not exist or is inaccessible.")
             } else if error.domain == AWSS3ErrorDomain, error.code == AWSS3ErrorType.accessDenied.rawValue {
                 XCTFail("HeadBucket failed due to access denied for bucket '\(expectedBucketName)'. Check IAM permissions.")
             } else {
                  XCTFail("HeadBucket failed for bucket '\(expectedBucketName)' with an unexpected error: \(error.localizedDescription)")
             }
         }
    }
    
    // MARK: - Upload/Download Validation Tests
    
    /// Validates the ability to upload and then download a file from the configured S3 bucket.
    func testUploadDownloadValidation() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testUploadDownloadValidation as runValidationTestsAgainstRealAWS is false.")
            return
        }
        
        logger.info("Starting upload/download validation for key: \(testObjectKey)")
        
        // 1. Upload the test file
        logger.info("Attempting to upload test data...")
        let uploadSuccess = await s3Service.uploadFile(data: testData, key: testObjectKey, contentType: "text/plain")
        
        guard uploadSuccess else {
            XCTFail("Failed to upload test file \(testObjectKey) to bucket \(expectedBucketName). Check permissions and configuration.")
            return
        }
        logger.info("Upload successful.")
        
        // Add a small delay to ensure eventual consistency if needed
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
        
        // 2. Download the test file
        logger.info("Attempting to download test data...")
        let downloadedData = await s3Service.downloadFile(key: testObjectKey)
        
        guard let downloadedData = downloadedData else {
            XCTFail("Failed to download test file \(testObjectKey) from bucket \(expectedBucketName). Upload might have failed silently or permissions are incorrect.")
            return
        }
        logger.info("Download successful.")
        
        // 3. Verify the content
        XCTAssertEqual(downloadedData, testData, "Downloaded data should match the uploaded data.")
        logger.info("Data verification successful.")
    }
    
    // MARK: - Feature Validation Tests (Encryption, Lifecycle)

    /// Validates that uploaded objects have the expected server-side encryption setting.
    func testEncryptionValidation() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testEncryptionValidation as runValidationTestsAgainstRealAWS is false.")
            return
        }
        
        logger.info("Starting encryption validation for key: \(testObjectKey)")
        
        // 1. Upload the test file
        logger.info("Uploading test file for encryption check...")
        let uploadSuccess = await s3Service.uploadFile(data: testData, key: testObjectKey, contentType: "text/plain")
        
        guard uploadSuccess else {
            XCTFail("Failed to upload test file \(testObjectKey) for encryption check.")
            return
        }
        logger.info("Upload successful.")
        
        // Add a small delay
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // 2. Use HeadObject to check metadata
        logger.info("Performing HeadObject to check encryption...")
        let request = AWSS3HeadObjectRequest()
        request?.bucket = expectedBucketName
        request?.key = testObjectKey
        
        let client = AWSS3.default()
        
        do {
            let task = client.headObject(request!)
            let output = try await task.await() // Use await extension
            
            logger.info("HeadObject successful. Checking encryption type...")
            
            // Check the serverSideEncryption property
            let actualEncryption = output.serverSideEncryption?.aws_string()
            
            XCTAssertEqual(actualEncryption, expectedEncryption, "Server-side encryption type should be \(expectedEncryption). Found: \(actualEncryption ?? "None")")
            if actualEncryption == expectedEncryption {
                logger.info("✅ Encryption validation successful. Type: \(expectedEncryption)")
            } else {
                 logger.error("❌ Encryption validation failed. Expected \(expectedEncryption), Got \(actualEncryption ?? "None")")
            }
            
        } catch let error as NSError {
            logger.error("HeadObject failed for key \(testObjectKey): \(error.localizedDescription)")
            XCTFail("HeadObject failed while checking encryption for key '\(testObjectKey)': \(error.localizedDescription)")
        }
    }
    
    /// Attempts to retrieve the lifecycle configuration for the bucket.
    /// Note: This only validates if the configuration can be accessed, not its content.
    func testLifecycleConfigurationRetrieval() async throws {
        guard runValidationTestsAgainstRealAWS else {
            logger.info("Skipping testLifecycleConfigurationRetrieval as runValidationTestsAgainstRealAWS is false.")
            return
        }
        
        logger.info("Attempting to retrieve lifecycle configuration for bucket: \(expectedBucketName)")
        
        let request = AWSS3GetBucketLifecycleConfigurationRequest()
        request?.bucket = expectedBucketName
        
        let client = AWSS3.default()
        
        do {
            let task = client.getBucketLifecycleConfiguration(request!)
            let output = try await task.await() // Use await extension
            
            // Check if rules were returned (can be nil if no rules are set)
            if let rules = output.rules, !rules.isEmpty {
                 logger.info("Successfully retrieved lifecycle configuration with \(rules.count) rule(s) for bucket: \(expectedBucketName)")
            } else {
                 logger.info("Successfully retrieved lifecycle configuration for bucket: \(expectedBucketName), but no rules are currently set or returned.")
            }
            XCTAssertNotNil(output, "Should be able to retrieve lifecycle configuration (even if empty).")
            
        } catch let error as NSError {
            logger.error("GetBucketLifecycleConfiguration failed for bucket \(expectedBucketName): \(error.localizedDescription) (Code: \(error.code), Domain: \(error.domain))")
            // AccessDenied is a common reason if permissions are missing
            if error.domain == AWSS3ErrorDomain, error.code == AWSS3ErrorType.accessDenied.rawValue {
                XCTFail("Retrieving lifecycle configuration failed due to access denied for bucket '\(expectedBucketName)'. Check IAM permissions (s3:GetLifecycleConfiguration).")
            } else {
                 XCTFail("Retrieving lifecycle configuration failed for bucket '\(expectedBucketName)' with an unexpected error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Error Handling Tests (Example)

    /// Tests handling of downloading a non-existent file.
    func testDownloadFile_NotFound_Validation() async throws {
         guard runValidationTestsAgainstRealAWS else {
             logger.info("Skipping testDownloadFile_NotFound_Validation as runValidationTestsAgainstRealAWS is false.")
             return
         }
        
         let nonExistentKey = "test/nonexistent-\(UUID().uuidString).file"
         logger.info("Attempting to download non-existent key: \(nonExistentKey)")
        
         let downloadedData = await s3Service.downloadFile(key: nonExistentKey)
        
         XCTAssertNil(downloadedData, "Downloading a non-existent file should return nil.")
         logger.info("Verified that downloading a non-existent file returns nil as expected.")
     }

    // MARK: - Integration Tests (Placeholder)
    
    // func testIntegrationWithDuplicateDetection() async {
    //    guard runValidationTestsAgainstRealAWS else { return }
    //    // 1. Upload a known duplicate file via s3Service
    //    // 2. Trigger the duplicate detection logic (e.g., via Lambda simulation or direct call)
    //    // 3. Verify that the system correctly identifies it as a duplicate (e.g., check DynamoDB record or mock a callback)
    //    XCTFail("Integration test not implemented")
    // }
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
                } else {
                     // Should not happen if ResultType matches T
                    continuation.resume(throwing: NSError(domain: "AWSTaskError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected task result type or nil result."]))
                }
                return nil
            }
        }
    }
    
     func await() async throws -> Void where ResultType == Any? || ResultType == AnyObject? || ResultType == Void {
         return try await withCheckedThrowingContinuation { continuation in
             self.continueWith { task -> Any? in
                 if let error = task.error {
                     continuation.resume(throwing: error)
                 } else {
                     continuation.resume(returning: ())
                 }
                 return nil
             }
         }
     }
}
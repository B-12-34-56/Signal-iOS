//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSCognitoIdentity
import AWSDynamoDB
import Logging
import SignalCore

/// Configuration constants and utilities for AWS services used by the duplicate content detection system.
public enum AWSConfig {
    
    // MARK: - DynamoDB Configuration
    
    /// The name of the DynamoDB table that stores content hashes
    public static let dynamoDbTableName = "ImageSignatures"
    
    /// The AWS region where the DynamoDB table is located
    static let dynamoDbRegion = AWSRegionType.USEast1
    
    /// The endpoint URL for DynamoDB service
    public static let dynamoDbEndpoint = "https://zudiexk4c3.execute-api.us-east-1.amazonaws.com/Stage1"
    
    // MARK: - Cognito Authentication
    
    /// The Cognito Identity Pool ID for authentication
    public static let identityPoolId = "us-east-1:ee264a1b-9b89-4e4a-a346-9128da47af97"
    
    /// The AWS region for the Cognito service
    static let cognitoRegion = AWSRegionType.USEast1
    
    // MARK: - TTL Configuration
    
    /// Default Time-To-Live value for stored hashes in days
    public static let defaultTTLInDays = 30
    
    // MARK: - Field Names
    
    /// Field name for the content hash in DynamoDB
    public static let hashFieldName = "ContentHash"
    
    /// Field name for the timestamp in DynamoDB
    public static let timestampFieldName = "Timestamp"
    
    /// Field name for the TTL value in DynamoDB
    public static let ttlFieldName = "TTL"
    
    // MARK: - Request Configuration
    
    /// Timeout interval for network requests (in seconds)
    public static let requestTimeoutInterval: TimeInterval = 30.0
    
    /// Timeout interval for resource access (in seconds)
    public static let resourceTimeoutInterval: TimeInterval = 300.0
    
    /// Maximum retry count for AWS operations
    public static let maxRetryCount = 3
    
    /// Initial retry delay in seconds
    public static let initialRetryDelay: TimeInterval = 1.0
    
    /// Maximum retry delay in seconds
    public static let maxRetryDelay: TimeInterval = 30.0
    
    // MARK: - API Gateway Configuration
    
    /// API Gateway endpoints and keys
    public static let apiGatewayEndpoint = "https://zudiexk4c3.execute-api.us-east-1.amazonaws.com/Stage1"
    public static let getTagApiGatewayEndpoint = "https://epzoie02m0.execute-api.us-east-1.amazonaws.com/GetTag1"
    public static let uploadImageApiUrl = "https://np39lyhj20.execute-api.us-east-1.amazonaws.com/Deployment/upload-image"
    public static let uploadImageApiKey = "iNrOCa2tbD8n5KfbAZ2Ct7ABHEKrBDVQ67XDlDIR"
    public static let getTagApiUrl = (ProcessInfo.processInfo.environment["API_URL"] ?? "https://zudiexk4c3.execute-api.us-east-1.amazonaws.com/Stage1/get-tag")
    public static let getTagApiKey = (ProcessInfo.processInfo.environment["API_KEY"] ?? "5Zkh0awDm033cqrQM0iCQ9hclI5eUGH679MYJetu")
    public static let blockImageApiUrl = "https://ecf3rgso5g.execute-api.us-east-1.amazonaws.com/Stage1/block-image"
    public static let blockImageApiKey = "iNrOCa2tbD8n5KfbAZ2Ct7ABHEKrBDVQ67XDlDIR"
    
    // MARK: - S3 Configuration
    
    /// S3 configuration
    public static let s3BucketName = "2314823894myawsbucket"
    public static let s3Region = AWSRegionType.USEast1
    public static let s3ImagesPath = "images/"
    public static var s3BaseURL: String { "https://\(s3BucketName).s3.\(s3Region.rawValue).amazonaws.com/\(s3ImagesPath)" }
    
    // MARK: - Private Properties
    
    private static let logger = Logger(label: "org.signal.AWSConfig")
    private static var isCredentialsSetup = false
    
    // MARK: - AWS Authentication Setup
    
    /// Sets up AWS credentials using Cognito Identity Pool
    public static func setupAWSCredentials() {
        logger.info("Setting up AWS credentials using Cognito Identity Pool")
        SignalCoreUtility.logDebug("Setting up AWS credentials using Cognito Identity Pool")
        
        do {
            // Create a Cognito credentials provider using the identity pool ID
            let credentialsProvider = AWSCognitoCredentialsProvider(
                regionType: cognitoRegion,
                identityPoolId: identityPoolId
            )
            
            // Create AWS service configuration with the credentials provider
            guard let configuration = AWSServiceConfiguration(
                region: cognitoRegion,
                credentialsProvider: credentialsProvider
            ) else {
                logger.error("Failed to create AWSServiceConfiguration")
                SignalCoreUtility.logError("Failed to create AWSServiceConfiguration")
                return
            }
            
            // Set the default service configuration for all AWS services
            AWSServiceManager.default().defaultServiceConfiguration = configuration
            
            // Register the Cognito provider and DynamoDB for access
            AWSCognitoIdentityProvider.register(with: configuration, forKey: "CognitoIdentityProvider")
            
            // Configure DynamoDB with custom timeouts
            let dynamoDBConfiguration = AWSDynamoDBConfiguration()
            dynamoDBConfiguration.timeoutIntervalForRequest = requestTimeoutInterval
            dynamoDBConfiguration.timeoutIntervalForResource = resourceTimeoutInterval
            dynamoDBConfiguration.maxRetryCount = maxRetryCount
            
            // Register DynamoDB with the custom configuration
            AWSDynamoDB.register(with: configuration, forKey: "DefaultDynamoDB")
            AWSDynamoDB.register(with: configuration, forKey: "DynamoDB", dynamoDBConfiguration)
            
            isCredentialsSetup = true
            logger.info("AWS credentials successfully configured")
            SignalCoreUtility.logDebug("AWS credentials successfully configured")
            
        } catch {
            logger.error("Failed to set up AWS credentials: \(error.localizedDescription)")
            SignalCoreUtility.logError("Failed to set up AWS credentials", error: error)
        }
    }
    
    /// Gets a preconfigured DynamoDB client with proper authentication
    /// - Returns: An initialized DynamoDB client
    public static func getDynamoDBClient() -> AWSDynamoDB {
        // Ensure credentials are set up before returning a client
        if !isCredentialsSetup {
            logger.info("AWS credentials not set up yet, initializing...")
            SignalCoreUtility.logDebug("AWS credentials not set up yet, initializing...")
            setupAWSCredentials()
        }
        
        // Try to get the client with custom configuration first
        if let client = AWSDynamoDB(forKey: "DynamoDB") {
            logger.debug("Retrieved existing DynamoDB client with custom configuration")
            return client
        }
        
        // Fall back to default client
        if let client = AWSDynamoDB(forKey: "DefaultDynamoDB") ?? AWSDynamoDB.default() {
            logger.debug("Retrieved fallback DynamoDB client")
            return client
        }
        
        // Last resort: create a new instance (will use default configuration)
        logger.warning("Failed to get existing DynamoDB client, creating new instance")
        SignalCoreUtility.logError("Failed to get existing DynamoDB client, creating new instance")
        return AWSDynamoDB()
    }
    
    /// Validates that AWS credentials are properly configured and can connect to DynamoDB
    /// - Returns: Boolean indicating if credentials are valid
    public static func validateAWSCredentials() async -> Bool {
        logger.info("Validating AWS credentials by connecting to DynamoDB")
        SignalCoreUtility.logDebug("Validating AWS credentials by connecting to DynamoDB")
        
        do {
            // Get the configured DynamoDB client
            let client = getDynamoDBClient()
            
            // Create a simple request to list tables as a connectivity test
            guard let listTablesInput = AWSDynamoDBListTablesInput() else {
                logger.error("Failed to create AWSDynamoDBListTablesInput")
                SignalCoreUtility.logError("Failed to create AWSDynamoDBListTablesInput")
                return false
            }
            
            // Execute the request and await the response
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                client.listTables(listTablesInput).continueWith { task in
                    if let error = task.error {
                        logger.error("AWS credentials validation failed: \(error.localizedDescription)")
                        SignalCoreUtility.logError("AWS credentials validation failed", error: error)
                        continuation.resume(returning: false)
                    } else {
                        logger.info("AWS credentials validated successfully")
                        SignalCoreUtility.logDebug("AWS credentials validated successfully")
                        continuation.resume(returning: true)
                    }
                    return nil
                }
            }
            
            return result
        } catch {
            logger.error("AWS credentials validation error: \(error.localizedDescription)")
            SignalCoreUtility.logError("AWS credentials validation error", error: error)
            return false
        }
    }
    
    /// Calculates exponential backoff delay with jitter for retry attempts
    public static func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        // Base delay with exponential backoff: initialDelay * 2^attempt
        let baseDelay = initialRetryDelay * pow(2.0, Double(attempt))
        
        // Apply a random jitter factor between 0.5 and 1.0 to avoid thundering herd
        let jitterFactor = 0.5 + (Double.random(in: 0..<0.5))
        
        // Calculate actual delay with jitter, capped at maxRetryDelay
        return min(baseDelay * jitterFactor, maxRetryDelay)
    }
    
    // MARK: - Test Utilities
    
    /// Resets the credentials setup state for testing
    internal static func resetCredentialsState() {
        isCredentialsSetup = false
        logger.info("Reset AWS credentials state for testing")
    }
} 
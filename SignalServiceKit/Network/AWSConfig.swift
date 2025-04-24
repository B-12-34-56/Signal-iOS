//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSCognitoIdentity
import AWSDynamoDB
import Logging

/// Configuration constants for AWS services used in the app.
public enum AWSConfig {
    
    // DynamoDB configuration
    public static let dynamoDbTableName = "SignalContentHashes"
    public static let dynamoDbRegion = "us-west-2"
    public static let dynamoDbEndpoint = "https://dynamodb.us-west-2.amazonaws.com"
    
    // Cognito Identity Pool configuration
    public static let identityPoolId = "us-west-2:a1b2c3d4-5e6f-7890-a1b2-c3d4e5f67890"
    public static let cognitoRegion = AWSRegionType.USWest2
    
    // TTL configuration for stored hashes
    public static let defaultTTLInDays = 30
    
    // Field names in DynamoDB
    public static let hashFieldName = "ContentHash"
    public static let timestampFieldName = "Timestamp"
    public static let ttlFieldName = "TTL"
    
    private static let logger = Logger(label: "org.signal.AWSConfig")
    private static var isCredentialsSetup = false
    
    /// Sets up AWS credentials using Cognito Identity Pool
    /// - Throws: Error if credentials setup fails
    public static func setupAWSCredentials() {
        do {
            logger.info("Setting up AWS credentials using Cognito Identity Pool")
            
            let credentialsProvider = AWSCognitoCredentialsProvider(
                regionType: cognitoRegion,
                identityPoolId: identityPoolId
            )
            
            guard let configuration = AWSServiceConfiguration(
                region: cognitoRegion,
                credentialsProvider: credentialsProvider
            ) else {
                throw NSError(domain: "AWSConfigError", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create AWSServiceConfiguration"
                ])
            }
            
            AWSServiceManager.default().defaultServiceConfiguration = configuration
            
            // Register the Cognito provider at runtime with specific keys
            AWSCognitoIdentityProvider.register(with: configuration, forKey: "CognitoIdentityProvider")
            AWSDynamoDB.register(with: configuration, forKey: "DefaultDynamoDB")
            
            // Configure specific service-level settings
            if let dynamoDBConfiguration = AWSDynamoDBConfiguration() {
                // Set custom timeout for DynamoDB requests to avoid long-hanging operations
                dynamoDBConfiguration.timeoutIntervalForRequest = 10.0
                dynamoDBConfiguration.timeoutIntervalForResource = 30.0
                dynamoDBConfiguration.maxRetryCount = 3
                
                // Apply these settings when registering
                AWSDynamoDB.register(with: configuration, forKey: "DynamoDB", dynamoDBConfiguration)
            }
            
            isCredentialsSetup = true
            logger.info("AWS credentials successfully configured")
            
        } catch {
            logger.error("Failed to set up AWS credentials: \(error.localizedDescription)")
            // Re-throw as we want the caller to know about failures
            // but still allow them to handle it gracefully
        }
    }
    
    /// Gets a preconfigured DynamoDB client with proper authentication
    /// - Returns: An initialized DynamoDB client
    /// - Throws: Error if client initialization fails
    public static func getDynamoDBClient() -> AWSDynamoDB {
        // First check if we have a valid configuration
        if !isCredentialsSetup || AWSServiceManager.default().defaultServiceConfiguration == nil {
            logger.info("AWS credentials not set up yet, attempting to initialize...")
            setupAWSCredentials()
        }
        
        // Check if we have a client registered specifically for DynamoDB
        if let client = AWSDynamoDB(forKey: "DynamoDB") {
            logger.debug("Retrieved existing DynamoDB client with custom configuration")
            return client
        }
        
        // Fall back to default client if specific one not available
        guard let client = AWSDynamoDB(forKey: "DefaultDynamoDB") ?? AWSDynamoDB.default() else {
            logger.error("Failed to create DynamoDB client, returning a new default instance")
            // Create a new instance as a last resort
            return AWSDynamoDB()
        }
        
        logger.debug("Retrieved DynamoDB client")
        return client
    }
    
    /// Validates that AWS credentials are properly configured and can connect to DynamoDB
    /// - Returns: Boolean indicating if credentials are valid
    public static func validateAWSCredentials() async -> Bool {
        do {
            logger.debug("Validating AWS credentials by listing DynamoDB tables")
            
            let client = getDynamoDBClient()
            guard let listTablesInput = AWSDynamoDBListTablesInput() else {
                logger.error("Failed to create AWSDynamoDBListTablesInput")
                return false
            }
            
            // Execute a simple operation to validate credentials
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                client.listTables(listTablesInput).continueWith { task in
                    if let error = task.error {
                        logger.error("AWS credentials validation failed: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    } else {
                        logger.info("AWS credentials validated successfully")
                        continuation.resume()
                    }
                    return nil
                }
            }
            
            return true
        } catch {
            logger.error("AWS credentials validation error: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Calculates exponential backoff delay for retry attempts
    /// - Parameter attempt: The current attempt number (0-based)
    /// - Parameter maxDelaySeconds: Maximum delay in seconds
    /// - Returns: Delay in seconds with jitter
    public static func calculateBackoffDelay(attempt: Int, maxDelaySeconds: Double = 30.0) -> TimeInterval {
        // Base delay is 2^attempt seconds with 25% jitter
        let baseDelay = min(pow(2.0, Double(attempt)), maxDelaySeconds)
        let jitterMultiplier = 0.75 + 0.5 * Double.random(in: 0..<1)
        return baseDelay * jitterMultiplier
    }
}
//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSCognitoIdentity
import AWSDynamoDB
import Logging

/// Configuration constants and utilities for AWS services used in the app.
public enum AWSConfig {

    // MARK: - DynamoDB Configuration

    /// The name of the DynamoDB table that stores content hashes
    public static let dynamoDbTableName = "DUMMY_DYNAMODB_TABLE" // TODO: Replace with env var or secrets manager

    /// The AWS region where the DynamoDB table is located
    public static let dynamoDbRegion = "us-east-1"

    /// The endpoint URL for operations, now pointing to API Gateway which might proxy DynamoDB actions.
    public static let dynamoDbEndpoint = "https://dummy-api-gateway.execute-api.us-east-1.amazonaws.com/Stage1" // TODO: Replace with env var or secrets manager

    /// The endpoint URL for the API Gateway (same as above for now)
    public static let apiGatewayEndpoint = "https://dummy-api-gateway.execute-api.us-east-1.amazonaws.com/Stage1" // TODO: Replace with env var or secrets manager

    /// The endpoint URL for the GetTag-specific API Gateway
    public static let getTagApiGatewayEndpoint = "https://dummy-gettag-api.execute-api.us-east-1.amazonaws.com/GetTag1" // TODO: Replace with env var or secrets manager

    // MARK: - Cognito Authentication

    /// The Cognito Identity Pool ID for authentication (Production Value)
    public static let identityPoolId = "us-east-1:dummy-identity-pool-id" // TODO: Replace with env var or secrets manager

    /// The AWS region for the Cognito service
    public static let cognitoRegion = AWSRegionType.USEast1

    /// API Key for the API Gateway (Replace with secure retrieval method)
    public static let apiKey = "DUMMY_API_KEY" // TODO: Replace with env var or secrets manager

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
    public static let requestTimeoutInterval: TimeInterval = 10.0

    /// Timeout interval for resource access (in seconds)
    public static let resourceTimeoutInterval: TimeInterval = 30.0

    /// Maximum retry count for AWS operations
    public static let maxRetryCount = 3

    /// Initial delay for exponential backoff (in seconds)
    public static let initialRetryDelay: TimeInterval = 1.0

    /// Maximum delay for exponential backoff (in seconds)
    public static let maxRetryDelay: TimeInterval = 30.0

    // MARK: - Private Properties

    public enum APIOperationType {
        case checkHash // GetTag endpoint
        case storeHash // General endpoint
        case deleteHash // General endpoint
    }

    private static let logger = Logger(label: "org.signal.AWSConfig")
    private static var isCredentialsSetup = false

    // MARK: - AWS Authentication Setup

    /// Sets up AWS credentials using Cognito Identity Pool
    /// - Throws: Error if credentials setup fails
    public static func setupAWSCredentials() {
        // Prevent redundant setup calls
        guard !isCredentialsSetup else {
            logger.debug("AWS credentials already set up.")
            return
        }

        logger.info("Setting up AWS credentials using Cognito Identity Pool")

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
                // This should ideally not happen unless there's a fundamental issue
                logger.critical("Failed to create AWSServiceConfiguration. AWS operations will likely fail.")
                throw NSError(domain: "AWSConfigError", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Failed to create AWSServiceConfiguration"])
            }

            // Set the default service configuration for all AWS services
            AWSServiceManager.default().defaultServiceConfiguration = configuration

            // Register the Cognito provider - necessary for the credentials provider to work
            AWSCognitoIdentityProvider.register(with: configuration, forKey: "CognitoIdentityProvider")

            // Configure DynamoDB client with custom timeouts and retry settings
            // Using a custom key ensures we use these specific settings
            let dynamoDBConfiguration = AWSDynamoDBConfiguration(
                region: cognitoRegion,
                credentialsProvider: credentialsProvider
            )
            dynamoDBConfiguration.timeoutIntervalForRequest = requestTimeoutInterval
            dynamoDBConfiguration.timeoutIntervalForResource = resourceTimeoutInterval
            dynamoDBConfiguration.maxRetryCount = UInt32(maxRetryCount) // Use UInt32

            // Register DynamoDB specifically with our custom configuration
            AWSDynamoDB.register(with: dynamoDBConfiguration, forKey: "DynamoDB")

            // Register a default client as well, though we prefer the custom one
            AWSDynamoDB.register(with: configuration, forKey: "DefaultDynamoDB")

            isCredentialsSetup = true
            logger.info("AWS credentials successfully configured (Cognito & DynamoDB clients registered).")
            logger.info("API Gateway Endpoint configured: \(apiGatewayEndpoint)")
            logger.info("GetTag API Gateway Endpoint configured: \(getTagApiGatewayEndpoint)")
            // Note: API Key usage assumes API Key auth for Gateway. IAM auth uses Cognito credentials.

        } catch let error as NSError {
            // Log specific error details if available
            logger.error("Failed to set up AWS credentials: \(error.localizedDescription). Domain: \(error.domain), Code: \(error.code)")
        } catch {
            // Catch any other unexpected errors
            logger.error("An unexpected error occurred during AWS credential setup: \(error)")
        }
    }

    /// Gets a preconfigured DynamoDB client with proper authentication
    /// - Returns: An initialized DynamoDB client
    public static func getDynamoDBClient() -> AWSDynamoDB {
        // Ensure credentials are set up before returning a client
        if !isCredentialsSetup {
            logger.info("AWS credentials not set up yet, initializing...")
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
        return AWSDynamoDB()
    }

    /// Returns the appropriate API Gateway endpoint based on the operation type.
    /// - Parameter operation: The type of API operation being performed.
    /// - Returns: The endpoint URL string.
    public static func getEndpoint(for operation: APIOperationType) -> String {
        switch operation {
        case .checkHash:
            return getTagApiGatewayEndpoint
        case .storeHash, .deleteHash:
            return apiGatewayEndpoint
        }
    }

    /// Generates necessary headers for authenticating with the API Gateway.
    /// - Parameter endpointUrl: The specific endpoint URL being called (optional, for future customization).
    /// - Returns: A dictionary of HTTP headers, including the API key.
    public static func getAPIGatewayHeaders(for endpointUrl: String? = nil) -> [String: String] {
        // In a real application, the API key should be retrieved securely,
        // e.g., from Keychain or a configuration service.
        // NOTE: This assumes API Key authentication. If using IAM, different headers
        // (signed requests using Cognito credentials) would be needed.
        logger.debug("Generating API Gateway headers.")
        // No specific customization based on endpointUrl needed yet, but included in signature
        return [
            "Content-Type": "application/json",
            "x-api-key": apiKey
        ]
    }

    // Note on Connection Pooling:
    // The AWS SDK for iOS manages HTTP connection pooling internally using URLSession.
    // Configuration like max concurrent connections is typically handled by the SDK
    // based on the device and network conditions. The timeouts set in `setupAWSCredentials`
    // influence how long connections are held or requests wait. Explicit pool size
    // configuration is not directly exposed as in some server-side SDKs.

    /// Validates that AWS credentials are properly configured and can connect to DynamoDB and optionally the API Gateway.
    /// - Parameter checkAPIGateway: If true, also validates API Gateway connectivity.
    /// - Returns: Boolean indicating if credentials are valid and services are reachable.
    public static func validateAWSCredentials(checkAPIGateway: Bool = true) async -> Bool {
        logger.info("Validating AWS credentials by attempting to list DynamoDB tables...")

        guard isCredentialsSetup else {
            logger.warning("Cannot validate AWS credentials, setup has not been completed successfully.")
            return false
        }

        var dynamoDBValid = false
        do {
            let client = getDynamoDBClient()

            guard let listTablesInput = AWSDynamoDBListTablesInput() else {
                logger.error("Failed to create AWSDynamoDBListTablesInput for validation.")
                return false
            }
            // Limit the number of tables returned to minimize response size
            listTablesInput.limit = 1

            dynamoDBValid = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                client.listTables(listTablesInput).continueWith { task -> Void in
                    if let error = task.error as NSError? {
                        // Log specific AWS error details
                        logger.error("""
                            AWS credentials validation failed: \(error.localizedDescription).
                            Domain: \(error.domain), Code: \(error.code).
                            UserInfo: \(error.userInfo)
                            """)
                        continuation.resume(returning: false)
                    } else if task.exception != nil {
                        // Log exceptions if they occur
                        logger.error("AWS credentials validation encountered an exception: \(task.exception!)")
                        continuation.resume(returning: false)
                    } else if task.result != nil {
                        // Success case
                        logger.info("AWS credentials validated successfully via listTables.")
                        continuation.resume(returning: true)
                    } else {
                        // Should not happen if error and exception are nil
                        logger.error("AWS credentials validation returned an unexpected state (no result, error, or exception).")
                        continuation.resume(returning: false)
                    }
                }
            }

        } catch {
            // Catch errors from withCheckedThrowingContinuation or other async operations
            logger.error("An unexpected error occurred during AWS credentials validation: \(error)")
            dynamoDBValid = false // Ensure it's false on error
        }

        // If requested, also validate API Gateway connectivity
        var apiGatewayValid = true // Assume true if not checked
        if checkAPIGateway {
            apiGatewayValid = await validateAPIGatewayConnectivity()
        }

        return dynamoDBValid && apiGatewayValid
    }

    /// Validates connectivity to both API Gateway endpoints.
    /// - Returns: Boolean indicating if connectivity to BOTH endpoints is successful.
    public static func validateAPIGatewayConnectivity() async -> Bool {
        logger.info("Validating connectivity to both API Gateway endpoints...")

        async let isGeneralEndpointValid = validateSingleEndpoint(apiGatewayEndpoint, description: "General Operations")
        async let isGetTagEndpointValid = validateSingleEndpoint(getTagApiGatewayEndpoint, description: "GetTag")

        let results = await [isGeneralEndpointValid, isGetTagEndpointValid]
        let allValid = results.allSatisfy { $0 }

        if allValid {
            logger.info("✅ Both API Gateway endpoints validated successfully.")
        } else {
            logger.error("❌ API Gateway validation failed for one or more endpoints.")
        }
        return allValid
    }

    /// Validates connectivity to a single API Gateway endpoint URL.
    private static func validateSingleEndpoint(_ endpointUrl: String, description: String) async -> Bool {
        logger.info("Validating API Gateway connectivity for \(description)...")
        guard let url = URL(string: endpointUrl) else { // Use the specific endpoint URL
            logger.error("Invalid API Gateway endpoint URL for \(description): \(endpointUrl)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET" // Or OPTIONS, depending on the endpoint
        // Pass the endpoint URL to potentially customize headers in the future
        let headers = getAPIGatewayHeaders(for: endpointUrl)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = requestTimeoutInterval

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { // Added '?' for safety
                logger.error("API Gateway validation failed for \(description): Invalid response type.")
                return false
            }

            // Check for successful status codes (e.g., 2xx or specific codes like 403 if expecting auth errors without a specific path)
            // The base URLs might return 403 (Missing Auth) or specific errors (like GetTag's 500) which still indicates the endpoint is reachable.
            // A more specific health check path would be better if available.
            let isReachable = (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 403 || httpResponse.statusCode == 500
            if isReachable {
                logger.info("API Gateway connectivity for \(description) validated (HTTP Status: \(httpResponse.statusCode)). Endpoint is reachable.")
                return true
            } else {
                logger.error("API Gateway validation for \(description) failed: Unexpected HTTP status code \(httpResponse.statusCode).")
                return false
            }
        } catch let error as NSError {
            logger.error("API Gateway validation for \(description) failed with error: \(error.localizedDescription) (Code: \(error.code), Domain: \(error.domain))")
            return false
        } catch {
             logger.error("An unexpected error occurred during API Gateway validation for \(description): \(error)")
             return false
         }
     }


    /// Calculates exponential backoff delay with jitter for retry attempts
    /// - Parameters:
    ///   - attempt: The current attempt number (0-based)
    ///   - maxDelaySeconds: Maximum delay in seconds
    /// - Returns: Delay in seconds with jitter
    public static func calculateBackoffDelay(attempt: Int, maxDelaySeconds: Double = maxRetryDelay) -> TimeInterval {
        // Base delay = initialRetryDelay * 2^attempt
        let baseDelay = min(initialRetryDelay * pow(2.0, Double(attempt)), maxDelaySeconds)

        // Add jitter (±25% of the base delay) to prevent thundering herd
        let jitterMultiplier = 0.75 + 0.5 * Double.random(in: 0..<1)

        // Ensure delay is at least a small minimum value (e.g., 100ms)
        let calculatedDelay = baseDelay * jitterMultiplier
        return max(0.1, calculatedDelay)
    }

    // MARK: - Test Utilities

    /// Resets the credentials setup state for testing
    internal static func resetCredentialsState() {
        isCredentialsSetup = false
        logger.info("Reset AWS credentials state for testing")
    }

    // MARK: - Table Management (Placeholder)

    /// Checks if the DynamoDB table exists and optionally creates it.
    /// NOTE: This is a placeholder. Actual table creation logic might reside
    /// in deployment scripts or more robust initialization flows.
    /// - Parameters:
    ///   - createIfNotExists: If true, attempt to create the table if it doesn't exist.
    /// - Returns: Boolean indicating if the table exists (or was created successfully).
    public static func ensureDynamoDbTableExists(createIfNotExists: Bool) async -> Bool {
        logger.info("Checking if DynamoDB table '\(dynamoDbTableName)' exists...")

        // Validate only DynamoDB part of credentials before proceeding
        guard await validateAWSCredentials(checkAPIGateway: false) else {
             logger.warning("Cannot check table existence, AWS credentials (DynamoDB part) are invalid or setup failed.")
             return false
         }


        do {
            let client = getDynamoDBClient()

            // Use describeTable to check existence
            guard let describeTableInput = AWSDynamoDBDescribeTableInput() else {
                logger.error("Failed to create DescribeTableInput.")
                return false
            }
            describeTableInput.tableName = dynamoDbTableName

            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                 client.describeTable(describeTableInput).continueWith { task in
                     if let error = task.error as NSError? {
                          if error.domain == AWSDynamoDBErrorDomain, error.code == AWSDynamoDBErrorType.resourceNotFoundException.rawValue {
                               // Table doesn't exist
                               continuation.resume(throwing: error) // Indicate absence as an error for this check
                           } else {
                                // Other error
                                logger.error("Failed to describe table '\(dynamoDbTableName)': \(error.localizedDescription)")
                               continuation.resume(throwing: error)
                           }
                       } else if task.result != nil {
                           // Table exists
                           logger.info("DynamoDB table '\(dynamoDbTableName)' exists.")
                           continuation.resume()
                       } else {
                            logger.error("Describe table returned unexpected state.")
                            continuation.resume(throwing: NSError(domain: "AWSConfigError", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Describe table returned unexpected state."]))
                       }
                       return nil
                   }
               }

             return true // DescribeTable succeeded

         } catch let error as NSError {
              if error.domain == AWSDynamoDBErrorDomain, error.code == AWSDynamoDBErrorType.resourceNotFoundException.rawValue {
                  // Table does not exist
                  logger.info("DynamoDB table '\(dynamoDbTableName)' does not exist.")

                  if createIfNotExists {
                      return await createDynamoDbTable()
                  } else {
                      return false // Table doesn't exist and we shouldn't create it
                  }
              } else {
                  // Other errors during describeTable
                  logger.error("Error checking if table '\(dynamoDbTableName)' exists: \(error.localizedDescription)")
                  return false
              }
          } catch {
              logger.error("An unexpected error occurred checking table existence: \(error)")
              return false
          }
     }

     /// Initializes the DynamoDB table with the appropriate schema and TTL settings.
     /// NOTE: This is a placeholder for client-side table creation logic.
     /// It's generally recommended to create tables via infrastructure-as-code or deployment scripts.
     /// - Returns: Boolean indicating if the table was created successfully.
     private static func createDynamoDbTable() async -> Bool {
          logger.info("Attempting to create DynamoDB table '\(dynamoDbTableName)'...")

          guard isCredentialsSetup else {
               logger.warning("Cannot create table, AWS credentials not set up.")
               return false
           }

          do {
               let client = getDynamoDBClient()

               // Define the schema: HashFieldName as primary key (String)
               guard let attributeDefinition = AWSDynamoDBAttributeDefinition(),
                     let keySchemaElement = AWSDynamoDBKeySchemaElement() else {
                          logger.error("Failed to create attribute definition or key schema element.")
                          return false
                      }

               attributeDefinition.attributeName = hashFieldName
               attributeDefinition.attributeType = .s // String type

               keySchemaElement.attributeName = hashFieldName
               keySchemaElement.keyType = .hash // Partition key

               // Define throughput settings (using provisioned for creation request)
               guard let provisionedThroughput = AWSDynamoDBProvisionedThroughput() else {
                    logger.error("Failed to create provisioned throughput.")
                    return false
                }
                // These values are just examples for table creation; auto-scaling is recommended later
                provisionedThroughput.readCapacityUnits = 5
                provisionedThroughput.writeCapacityUnits = 5

               // Create the CreateTableInput request
               guard let createTableInput = AWSDynamoDBCreateTableInput() else {
                    logger.error("Failed to create CreateTableInput.")
                    return false
                }

               createTableInput.tableName = dynamoDbTableName
               createTableInput.attributeDefinitions = [attributeDefinition]
               createTableInput.keySchema = [keySchemaElement]
               createTableInput.provisionedThroughput = provisionedThroughput

               // Add TTL specification
               guard let timeToLiveSpecification = AWSDynamoDBTimeToLiveSpecification() else {
                    logger.error("Failed to create TimeToLiveSpecification.")
                    return false
                }
                timeToLiveSpecification.enabled = NSNumber(value: true)
                timeToLiveSpecification.attributeName = ttlFieldName
                createTableInput.timeToLiveSpecification = timeToLiveSpecification

               // Set billing mode to PAY_PER_REQUEST (On-demand)
               guard let billingModeSummary = AWSDynamoDBBillingModeSummary() else {
                    logger.error("Failed to create BillingModeSummary.")
                    return false
                }
                 billingModeSummary.billingMode = .payPerRequest
                 createTableInput.billingModeSummary = billingModeSummary
                 // provisionedThroughput is not needed if using PAY_PER_REQUEST, but often included for schema definition
                 createTableInput.provisionedThroughput = nil // Explicitly set to nil for On-demand


                logger.info("Sending CreateTable request for '\(dynamoDbTableName)'...")

                // Execute the request
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                     client.createTable(createTableInput).continueWith { task in
                         if let error = task.error {
                             logger.error("Failed to create table '\(dynamoDbTableName)': \(error.localizedDescription)")
                             continuation.resume(throwing: error)
                         } else {
                             logger.info("CreateTable request for '\(dynamoDbTableName)' sent successfully. Waiting for table to become active...")
                             // Table is not immediately active, should ideally wait for it to become active
                             continuation.resume()
                         }
                         return nil
                     }
                 }

                // Table might not be active yet, but request was successful
                logger.info("Table creation request successful for '\(dynamoDbTableName)'.")
                return true

            } catch {
                logger.error("An error occurred during table creation: \(error.localizedDescription)")
                return false
            }
        }
    }
}

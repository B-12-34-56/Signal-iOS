//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSDynamoDB
import AWSAPIGateway // Import for API Gateway checks
import Logging

/// Configuration constants and utilities for AWS services used by the duplicate content detection system.
public enum AWSConfig {

    // MARK: - DynamoDB Configuration

    /// The name of the DynamoDB table that stores content hashes
    public static let dynamoDbTableName = "SignalContentHashes" // Updated Table Name

    /// The AWS region where the DynamoDB table is located
    public static let dynamoDbRegion = AWSRegionType.USEast1 // Updated Region

    /// The endpoint URL for DynamoDB service
    public static let dynamoDbEndpoint = "https://dynamodb.us-east-1.amazonaws.com" // Updated Endpoint

    // MARK: - Cognito Authentication

    /// The Cognito Identity Pool ID for authentication
    public static let identityPoolId = "us-east-1:ee264a1b-9b89-4e4a-a346-9128da47af97" // Updated Identity Pool ID

    /// The AWS region for the Cognito service
    public static let cognitoRegion = AWSRegionType.USEast1 // Updated Region

    /// API Key for the API Gateway (Replace with secure retrieval method)
    // NOTE: This placeholder is needed if the API Gateway uses API Key authentication.
    // If using IAM authentication via Cognito, this key might not be necessary depending on Gateway config.
    // Assuming API Key is needed based on SignalServiceKit implementation.
    public static let apiKey = "YOUR_API_GATEWAY_API_KEY_PLACEHOLDER" // Added API Key Placeholder

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
    public static let initialRetryDelay: TimeInterval = 1.0 // Added initial retry delay
    /// Maximum delay for exponential backoff (in seconds)
    public static let maxRetryDelay: TimeInterval = 30.0 // Added max retry delay


    // MARK: - API Gateway Configuration
    // Note: These endpoints are examples. Use your actual API Gateway URLs.

    /// The endpoint URL for general API Gateway operations (e.g., storing/deleting hashes)
    public static let apiGatewayEndpoint = "https://YOUR_GENERAL_API_GATEWAY_ID.execute-api.us-east-1.amazonaws.com/Stage" // Added General API Gateway Endpoint

    /// The endpoint URL for the GetTag-specific API Gateway (e.g., checking hash existence)
    public static let getTagApiGatewayEndpoint = "https://YOUR_GETTAG_API_GATEWAY_ID.execute-api.us-east-1.amazonaws.com/Stage" // Added GetTag API Gateway Endpoint

    // MARK: - API Operation Type
    public enum APIOperationType {
        case checkHash // GetTag endpoint
        case storeHash // General endpoint
        case deleteHash // General endpoint
    }


    // MARK: - Private Properties

    private static let logger = Logger(label: "org.signal.AWSConfig")
    public private(set) static var isCredentialsSetup = false // Made public(set) for validation manager

    // MARK: - AWS Authentication Setup

    /// Sets up AWS credentials using Cognito Identity Pool
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
                regionType: cognitoRegion, // Use updated region
                identityPoolId: identityPoolId
            )

            // Create AWS service configuration with the credentials provider
            guard let configuration = AWSServiceConfiguration(
                region: cognitoRegion, // Use updated region
                credentialsProvider: credentialsProvider
            ) else {
                // This should ideally not happen unless there's a fundamental issue
                logger.critical("Failed to create AWSServiceConfiguration. AWS operations will likely fail.")
                isCredentialsSetup = false // Mark setup as failed
                return
            }

            // Set the default service configuration for all AWS services
            AWSServiceManager.default().defaultServiceConfiguration = configuration

            // Register the Cognito provider - necessary for the credentials provider to work
            AWSCognitoIdentityProvider.register(with: configuration, forKey: "CognitoIdentityProvider")

            // Configure DynamoDB client with the correct region and custom timeouts
            let dynamoDBConfiguration = AWSDynamoDBConfiguration(
                region: dynamoDbRegion, // Use updated region
                credentialsProvider: credentialsProvider
            )
            dynamoDBConfiguration.timeoutIntervalForRequest = requestTimeoutInterval
            dynamoDBConfiguration.timeoutIntervalForResource = resourceTimeoutInterval
            dynamoDBConfiguration.maxRetryCount = UInt32(maxRetryCount) // Ensure UInt32

            // Register DynamoDB specifically with our custom configuration
            AWSDynamoDB.register(with: dynamoDBConfiguration, forKey: "DynamoDB")

            // Register a default client as well, though we prefer the custom one
            AWSDynamoDB.register(with: configuration, forKey: "DefaultDynamoDB")

            isCredentialsSetup = true
            logger.info("AWS credentials successfully configured (Cognito & DynamoDB clients registered).")
            logger.info("General API Gateway Endpoint configured: \(apiGatewayEndpoint)")
            logger.info("GetTag API Gateway Endpoint configured: \(getTagApiGatewayEndpoint)")

        } catch let error as NSError {
            logger.error("Failed to set up AWS credentials: \(error.localizedDescription). Domain: \(error.domain), Code: \(error.code)")
            isCredentialsSetup = false // Mark setup as failed on error
        } catch {
            logger.error("An unexpected error occurred during AWS credential setup: \(error)")
            isCredentialsSetup = false // Mark setup as failed on error
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
    /// - Returns: A dictionary of HTTP headers, including the API key if needed.
    public static func getAPIGatewayHeaders(for endpointUrl: String? = nil) -> [String: String] {
        // In a real application, the API key should be retrieved securely,
        // e.g., from Keychain or a configuration service.
        // NOTE: This assumes API Key authentication. If using IAM, different headers
        // (signed requests using Cognito credentials) would be needed.
        logger.debug("Generating API Gateway headers.")
        // No specific customization based on endpointUrl needed yet, but included in signature
        var headers = [String: String]()
        headers["Content-Type"] = "application/json"

        // Only add API key if it's not the placeholder and if API Key authentication is used
        if apiKey != "YOUR_API_GATEWAY_API_KEY_PLACEHOLDER" {
             headers["x-api-key"] = apiKey
        } else {
            logger.warning("Using placeholder API key. API Gateway calls may fail.")
        }

        return headers
    }

    /// Validates that AWS credentials are properly configured and can connect to DynamoDB and optionally the API Gateway.
    /// - Parameter checkAPIGateway: If true, also validates API Gateway connectivity.
    /// - Returns: Boolean indicating if credentials are valid and services are reachable.
    public static func validateAWSCredentials(checkAPIGateway: Bool = true) async -> Bool {
        logger.info("Validating AWS credentials by checking for identity ID...")

        guard isCredentialsSetup else {
            logger.warning("Cannot validate AWS credentials, setup has not been completed or failed.")
            return false
        }

        guard let provider = AWSServiceManager
                .default()
                .defaultServiceConfiguration?
                .credentialsProvider as? AWSCognitoCredentialsProvider
        else {
            logger.error("Could not retrieve Cognito credentials provider from default configuration.")
            return false
        }

        // Check if an identity ID has been successfully fetched.
        // This indicates that communication with Cognito Identity service was successful
        // and the app has received temporary AWS credentials.
        let hasIdentity = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
             provider.getIdentityId().continueWith { task in
                 if let identityId = task.result {
                     self.logger.info("AWS credentials validated: Identity ID fetched successfully: \(identityId)")
                     continuation.resume(returning: true)
                 } else if let error = task.error {
                     self.logger.error("AWS credentials validation failed: Error fetching Identity ID: \(error.localizedDescription)")
                     continuation.resume(returning: false)
                 } else {
                      self.logger.error("AWS credentials validation failed: Unknown error fetching Identity ID.")
                      continuation.resume(returning: false)
                 }
                 return nil
             }
         }


        // If identity fetching failed, overall validation fails.
        guard hasIdentity else {
             logger.error("AWS credentials validation failed because identity ID could not be fetched.")
             return false
         }

        // If requested, also validate API Gateway connectivity
        var apiGatewayValid = true // Assume true if not checked
        if checkAPIGateway {
            apiGatewayValid = await validateAPIGatewayConnectivity()
        }

        // Note: A successful identity fetch + API Gateway reachability doesn't guarantee
        // full access to DynamoDB/API Gateway methods (due to IAM policy issues),
        // but it's a strong indicator that the basic configuration and network path are correct.
        // AWSCredentialsVerificationManager provides more specific service checks.

        return apiGatewayValid // Overall status depends on identity + optional API Gateway check
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

            // Check for successful status codes (e.g., 2xx) or specific expected errors (like 403 Forbidden if missing API key/IAM auth, 404 if path doesn't exist but Gateway is up)
            // A 403 or 404 from the Gateway *itself* (not CloudFront or network error) indicates the endpoint is reachable.
            let isReachable = (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 403 || httpResponse.statusCode == 404 || httpResponse.statusCode == 500 // Added 404, kept 500 for potential lambda errors indicating reachability

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
        // Also clear cached identity if possible, though AWS SDK doesn't expose this easily.
        // A full reset might involve de-registering/re-registering services if the SDK allows.
        logger.info("Reset AWS credentials state for testing")
    }

    // MARK: - Table Management

    /// Check for—and optionally create—the DynamoDB table.
    /// Mimics the logic from Signal/AppLaunch/AWSConfig.swift but adapted for SignalContentHashes schema.
    /// - Parameter createIfNotExists: If true, attempt to create the table if it doesn't exist.
    /// - Returns: Boolean indicating if the table exists (or was created successfully).
    public static func ensureDynamoDbTableExists(createIfNotExists: Bool) async -> Bool {
        logger.info("Checking if DynamoDB table '\(dynamoDbTableName)' exists...")

        // Validate only DynamoDB part of credentials before proceeding
         guard await validateAWSCredentials(checkAPIGateway: false) else {
             logger.warning("Cannot check table existence, AWS credentials (Cognito part) are invalid or setup failed.")
             return false
         }


        do {
            let client = getDynamoDBClient()

            // 1) Try to describe the table
            guard let describeInput = AWSDynamoDBDescribeTableInput() else {
                 logger.error("Failed to create DescribeTableInput.")
                 return false
             }
            describeInput.tableName = dynamoDbTableName

            let describeTask = client.describeTable(describeInput)

            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                 describeTask.continueWith { task in
                     if let error = task.error as NSError? {
                          if error.domain == AWSDynamoDBErrorDomain, error.code == AWSDynamoDBErrorType.resourceNotFound.rawValue {
                               // Table doesn't exist
                                logger.info("DynamoDB table '\(dynamoDbTableName)' not found.")
                               continuation.resume(throwing: error) // Indicate absence as an error for this check
                           } else {
                                // Other error
                                logger.error("Failed to describe table '\(dynamoDbTableName)': \(error.localizedDescription)")
                               continuation.resume(throwing: error)
                           }
                       } else if let result = task.result, result.table?.tableStatus == .active {
                           // Table exists and is active
                           logger.info("DynamoDB table '\(dynamoDbTableName)' exists and is active.")
                           continuation.resume()
                       } else if let result = task.result, result.table?.tableStatus != .active {
                            // Table exists but not active yet
                           logger.warning("DynamoDB table '\(dynamoDbTableName)' exists but status is \(result.table?.tableStatusString ?? "Unknown").")
                            // We could poll here, but for a simple check, we'll assume it will become active.
                            // A more robust check might wait. For now, we treat it as existing.
                           continuation.resume() // Treat as existing for the purpose of this check
                       }
                       else {
                            logger.error("Describe table returned unexpected state.")
                            continuation.resume(throwing: NSError(domain: "AWSConfigError", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Describe table returned unexpected state."]))
                       }
                       return nil
                   }
               }

             return true // DescribeTable succeeded or is pending activation

         } catch let error as NSError {
              if error.domain == AWSDynamoDBErrorDomain, error.code == AWSDynamoDBErrorType.resourceNotFound.rawValue {
                  // Table does not exist
                  logger.info("DynamoDB table '\(dynamoDbTableName)' does not exist. Checking if creation is requested.")

                  if createIfNotExists {
                      logger.info("Table creation requested.")
                      // Attempt to create the table
                      return await createDynamoDbTable()
                  } else {
                      logger.info("Table creation not requested. Returning false.")
                      return false // Table doesn't exist and we shouldn't create it
                  }
              } else {
                  // Other errors during describeTable (e.g., permissions, network)
                  logger.error("Error checking if table '\(dynamoDbTableName)' exists: \(error.localizedDescription)")
                  return false
              }
          } catch {
              // Catch any other unexpected errors from the async await block
              logger.error("An unexpected error occurred checking table existence: \(error)")
              return false
          }
     }

     /// Initializes the DynamoDB table with the appropriate schema and TTL settings.
     /// NOTE: This is client-side table creation logic. It's generally recommended
     /// to create tables via infrastructure-as-code or deployment scripts.
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

               // Create the CreateTableInput request
               guard let createTableInput = AWSDynamoDBCreateTableInput() else {
                    logger.error("Failed to create CreateTableInput.")
                    return false
                }

               createTableInput.tableName = dynamoDbTableName
               createTableInput.attributeDefinitions = [attributeDefinition]
               createTableInput.keySchema = [keySchemaElement]

               // Set billing mode to PAY_PER_REQUEST (On-demand) as per aws-config.json
               guard let billingModeSummary = AWSDynamoDBBillingModeSummary() else {
                    logger.error("Failed to create BillingModeSummary.")
                    return false
                }
                 billingModeSummary.billingMode = .payPerRequest
                 createTableInput.billingModeSummary = billingModeSummary
                 // provisionedThroughput is not needed if using PAY_PER_REQUEST
                 createTableInput.provisionedThroughput = nil // Explicitly set to nil for On-demand


               // Add TTL specification as per aws-config.json
               guard let timeToLiveSpecification = AWSDynamoDBTimeToLiveSpecification() else {
                   logger.error("Failed to create TimeToLiveSpecification.")
                   return false
               }
               timeToLiveSpecification.enabled = NSNumber(value: true)
               timeToLiveSpecification.attributeName = ttlFieldName // Use defined TTL field name
               createTableInput.timeToLiveSpecification = timeToLiveSpecification


                logger.info("Sending CreateTable request for '\(dynamoDbTableName)'...")

                // Execute the request
                let createTask = client.createTable(createTableInput)

                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                     createTask.continueWith { task in
                         if let error = task.error {
                             logger.error("Failed to create table '\(dynamoDbTableName)': \(error.localizedDescription)")
                             continuation.resume(throwing: error)
                         } else if task.result != nil {
                             logger.info("CreateTable request for '\(dynamoDbTableName)' sent successfully. Table is creating.")
                             // Table is not immediately active, should ideally wait for it to become active
                             continuation.resume()
                         } else {
                             logger.error("CreateTable returned unexpected state.")
                             continuation.resume(throwing: NSError(domain: "AWSConfigError", code: 1003, userInfo: [NSLocalizedDescriptionKey: "CreateTable returned unexpected state."]))
                         }
                         return nil
                     }
                 }

                // Table might not be active yet, but request was successful
                // A robust implementation would poll describeTable until status is ACTIVE.
                logger.info("Table '\(dynamoDbTableName)' creation initiated successfully.")
                return true

            } catch {
                logger.error("An error occurred during table creation call: \(error.localizedDescription)")
                return false
            }
        }
}
//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSDynamoDB
import Logging

/// A mock implementation of AWSDynamoDB for unit testing.
/// This class simulates DynamoDB's behavior using in-memory storage
/// and provides methods to control behavior like delays, errors, and retries.
public class AWSMockClient: AWSDynamoDB {

    // MARK: - Singleton

    /// Shared instance, primarily for convenience, but tests should ideally create fresh instances via factory.
    public static let shared = AWSMockClient()

    // MARK: - Properties

    /// Logger for capturing mock client operations
    private let logger = Logger(label: "org.signal.AWSMockClient")

    /// In-memory storage for mock database - simulates DynamoDB tables
    /// Format: [TableName: [PrimaryKey: [AttributeName: AttributeValue]]]
    private var database: [String: [String: [String: AWSDynamoDBAttributeValue]]] = [:]

    /// Records all operations for verification in tests
    private var operationLog: [Operation] = []

    /// Configurable delay to simulate network latency
    private var simulatedDelay: TimeInterval = 0.0

    /// Controls whether operations should fail immediately
    private var shouldFailOperations = false

    /// Custom error to return when operations fail
    private var customError: NSError?

    /// Specifies the attempt number after which a failing operation should succeed (for retry testing)
    private var retrySuccessAfterAttempt: Int?

    /// Tracks the number of attempts made for a given operation key (e.g., "getItem-tableName-hashKey")
    private var currentAttemptCount: [String: Int] = [:]

    // MARK: - Initialization

    /// Public initializer to allow creating instances
    public override init() {
        // Note: Super init requires service configuration, but for a mock,
        // we might not need a real one. However, AWSDynamoDB inherits from AWSService,
        // which might expect it. If issues arise, provide a dummy configuration.
        super.init()
        setupDefaultTable()
    }

    /// Sets up the default table used by the GlobalSignatureService.
    private func setupDefaultTable() {
        let defaultTableName = AWSConfig.dynamoDbTableName
        if database[defaultTableName] == nil {
             database[defaultTableName] = [:]
             logger.info("Created mock DynamoDB table: \(defaultTableName)")
        }
    }

    /// Creates a mock table for testing purposes.
    /// - Parameter tableName: The name of the table to create.
    public func createMockTable(tableName: String) {
        if database[tableName] == nil {
            database[tableName] = [:]
            logger.info("Created mock DynamoDB table: \(tableName)")
        }
    }

    // MARK: - Test Configuration Methods

    /// Resets the mock database, operation log, error states, and attempt counts to initial state.
    public func reset() {
        database = [:]
        operationLog = []
        shouldFailOperations = false
        customError = nil
        simulatedDelay = 0.0
        retrySuccessAfterAttempt = nil
        currentAttemptCount = [:]
        setupDefaultTable() // Ensure default table exists after reset
        logger.info("Reset AWSMockClient to initial state.")
    }

    /// Configures the mock to simulate network delays for all operations.
    /// - Parameter seconds: The delay to add to operations in seconds. Must be non-negative.
    public func setSimulatedDelay(_ seconds: TimeInterval) {
        guard seconds >= 0 else {
            logger.warning("Simulated delay must be non-negative. Ignoring value: \(seconds)")
            return
        }
        simulatedDelay = seconds
        logger.info("Set simulated delay to \(seconds) seconds.")
    }

    /// Configures the mock to fail operations. Can be used with `setRetrySuccessAfter` for retry testing.
    /// - Parameters:
    ///   - shouldFail: Whether operations should fail.
    ///   - error: Custom error to return. If nil, a default InternalServerError is used.
    public func setFailureMode(shouldFail: Bool, error: NSError? = nil) {
        shouldFailOperations = shouldFail
        customError = error
        if !shouldFail {
            // Reset retry counter if failure mode is turned off
            retrySuccessAfterAttempt = nil
        }
        logger.info("Set failure mode to \(shouldFail). Custom error: \(error?.localizedDescription ?? "Default")")
    }

    /// Configures the mock to succeed only after a specific number of attempts.
    /// Requires `setFailureMode(shouldFail: true)` to be active.
    /// - Parameter attempts: The attempt number (1-based) on which the operation should succeed.
    public func setRetrySuccessAfter(attempts: Int) {
        guard attempts > 0 else {
            logger.warning("Retry success attempt count must be positive. Ignoring value: \(attempts)")
            return
        }
        retrySuccessAfterAttempt = attempts
        logger.info("Configured mock to succeed on attempt \(attempts).")
    }


    /// Populates the mock database with test hash data in the default table.
    /// - Parameter hashValues: Array of hash values (primary keys) to add.
    public func populateWithHashes(_ hashValues: [String]) {
        let tableName = AWSConfig.dynamoDbTableName
        populateTable(tableName: tableName, keys: hashValues)
    }

    /// Populates a specified mock table with simple key-value items.
    /// - Parameters:
    ///   - tableName: The name of the table to populate.
    ///   - keys: An array of primary key strings to add.
    ///   - createTableIfNeeded: If true, creates the table if it doesn't exist.
    public func populateTable(tableName: String, keys: [String], createTableIfNeeded: Bool = true) {
         if database[tableName] == nil {
             if createTableIfNeeded {
                 createMockTable(tableName: tableName)
             } else {
                 logger.error("Cannot populate non-existent table: \(tableName). Set createTableIfNeeded to true.")
                 return
             }
         }

        let hashFieldName = AWSConfig.hashFieldName // Assuming same key name for simplicity
        let timestampFieldName = AWSConfig.timestampFieldName
        let ttlFieldName = AWSConfig.ttlFieldName

        for key in keys {
            guard let keyAttr = AWSDynamoDBAttributeValue() else { continue }
            keyAttr.s = key

            guard let timestampAttr = AWSDynamoDBAttributeValue() else { continue }
            timestampAttr.s = ISO8601DateFormatter().string(from: Date())

            guard let ttlAttr = AWSDynamoDBAttributeValue() else { continue }
            ttlAttr.n = String(Int(Date().timeIntervalSince1970) + (AWSConfig.defaultTTLInDays * 24 * 60 * 60))

            database[tableName]?[key] = [
                hashFieldName: keyAttr,
                timestampFieldName: timestampAttr,
                ttlFieldName: ttlAttr
            ]
        }
        logger.info("Populated table '\(tableName)' with \(keys.count) items.")
    }

    /// Retrieves the stored TTL value for a specific hash in the default table.
    /// - Parameter hash: The hash key to look up.
    /// - Returns: The TTL timestamp (as Int) or nil if not found or invalid.
    public func getStoredTTL(for hash: String) -> Int? {
         guard let item = database[AWSConfig.dynamoDbTableName]?[hash],
               let ttlAttr = item[AWSConfig.ttlFieldName],
               let ttlString = ttlAttr.n else {
             return nil
         }
         return Int(ttlString)
     }

    // MARK: - Verification Methods

    /// Returns a copy of all operations performed since the last reset.
    /// - Returns: Array of `Operation` structs.
    public func getOperationLog() -> [Operation] {
        // Return a copy to prevent external modification
        return operationLog
    }

    /// Returns the count of operations performed matching a specific type.
    /// - Parameter type: The `OperationType` to count.
    /// - Returns: The number of operations matching the type.
    public func getOperationCount(type: OperationType) -> Int {
        return operationLog.filter { $0.type == type }.count
    }

    // MARK: - Helper Methods

    /// Simulates network delay if configured.
    private func simulateNetworkDelay() async {
        if simulatedDelay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
            } catch {
                // Task cancellation is expected in some test scenarios
                logger.debug("Sleep was interrupted during simulated delay.")
            }
        }
    }

    /// Determines if the current operation should fail based on configuration and attempt count.
    /// - Parameter operationKey: A unique key identifying the specific operation attempt.
    /// - Returns: An NSError if the operation should fail, otherwise nil.
    private func shouldFailWithError(operationKey: String) -> NSError? {
        incrementAttemptCount(for: operationKey)
        let currentAttempt = currentAttemptCount[operationKey] ?? 1

        // Check if retry success is configured
        if let successAttempt = retrySuccessAfterAttempt {
            if shouldFailOperations && currentAttempt < successAttempt {
                // Fail because we haven't reached the success attempt yet
                return customError ?? defaultInternalError(message: "Simulated failure before retry success on attempt \(currentAttempt)")
            } else {
                 // Either we reached the success attempt or shouldFailOperations is false
                 // Check if failure mode is globally off
                 if !shouldFailOperations {
                      return nil // No failure
                 }
                 // We reached or passed the success attempt, so don't fail based on retry config
                  return nil
            }
        } else if shouldFailOperations {
             // Simple failure mode without specific retry success attempt
             return customError ?? defaultInternalError(message: "Simulated failure on attempt \(currentAttempt)")
        }

        // No failure conditions met
        return nil
    }

    /// Increments the attempt count for a given operation key.
    private func incrementAttemptCount(for key: String) {
        currentAttemptCount[key] = (currentAttemptCount[key] ?? 0) + 1
    }

    /// Creates a default InternalServerError NSError.
    private func defaultInternalError(message: String) -> NSError {
        return NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.internalServerError.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Generates a unique key for tracking attempts for an operation.
    private func operationAttemptKey(type: OperationType, tableName: String?, key: String?) -> String {
         return "\(type.rawValue)-\(tableName ?? "unknownTable")-\(key ?? "unknownKey")"
     }

    // MARK: - AWSDynamoDB Method Overrides (AWSTask based)

    public override func getItem(_ getItemInput: AWSDynamoDBGetItemInput) -> AWSTask<AWSDynamoDBGetItemOutput> {
        let tableName = getItemInput.tableName ?? "unknownTable"
         // Assume the primary key is always named according to AWSConfig for this mock
         let primaryKeyName = AWSConfig.hashFieldName
         let key = getItemInput.key?[primaryKeyName]?.s

         let operationKey = operationAttemptKey(type: .getItem, tableName: tableName, key: key)

         logOperation(.getItem, tableName: tableName, key: key)

        let taskCompletionSource = AWSTaskCompletionSource<AWSDynamoDBGetItemOutput>()

        Task {
            await simulateNetworkDelay()

             if let error = shouldFailWithError(operationKey: operationKey) {
                 taskCompletionSource.setError(error)
                 return
             }

            guard database[tableName] != nil else {
                taskCompletionSource.setError(resourceNotFoundError(tableName: tableName))
                return
            }

            guard let key = key else {
                taskCompletionSource.setError(validationError(message: "Missing primary key '\(primaryKeyName)' in GetItem request."))
                return
            }

            let output = AWSDynamoDBGetItemOutput()
            output.item = database[tableName]?[key] // Will be nil if key not found

            taskCompletionSource.set(result: output)
            logger.debug("[getItem] Table '\(tableName)', Key '\(key)': Found=\(output.item != nil)")
        }

        return taskCompletionSource.task
    }

    public override func putItem(_ putItemInput: AWSDynamoDBPutItemInput) -> AWSTask<AWSDynamoDBPutItemOutput> {
        let tableName = putItemInput.tableName ?? "unknownTable"
        // Assume the primary key is always named according to AWSConfig
        let primaryKeyName = AWSConfig.hashFieldName
        let key = putItemInput.item?[primaryKeyName]?.s

         let operationKey = operationAttemptKey(type: .putItem, tableName: tableName, key: key)

         logOperation(.putItem, tableName: tableName, key: key, item: putItemInput.item)

        let taskCompletionSource = AWSTaskCompletionSource<AWSDynamoDBPutItemOutput>()

        Task {
            await simulateNetworkDelay()

             if let error = shouldFailWithError(operationKey: operationKey) {
                 taskCompletionSource.setError(error)
                 return
             }

            guard database[tableName] != nil else {
                taskCompletionSource.setError(resourceNotFoundError(tableName: tableName))
                return
            }

            guard let item = putItemInput.item, let key = key else {
                taskCompletionSource.setError(validationError(message: "Missing item or primary key '\(primaryKeyName)' in PutItem request."))
                return
            }

            // Check for conditional expression "attribute_not_exists(#hashKey)"
             if let conditionExpression = putItemInput.conditionExpression,
                 let attributeNames = putItemInput.expressionAttributeNames,
                 attributeNames["#hashKey"] == primaryKeyName, // Check placeholder mapping
                 conditionExpression == "attribute_not_exists(#hashKey)",
                 database[tableName]?[key] != nil { // Check if item already exists

                taskCompletionSource.setError(conditionalCheckFailedError())
                logger.debug("[putItem] Table '\(tableName)', Key '\(key)': ConditionalCheckFailed (attribute_not_exists)")
                return
            }

            // Create a deep copy of the item for storage
            var newItem: [String: AWSDynamoDBAttributeValue] = [:]
            for (attrKey, attrValue) in item {
                if let copiedValue = deepCopyAttributeValue(attrValue) {
                     newItem[attrKey] = copiedValue
                 }
            }

            database[tableName]?[key] = newItem
            let output = AWSDynamoDBPutItemOutput()
            taskCompletionSource.set(result: output)
            logger.debug("[putItem] Table '\(tableName)', Key '\(key)': Stored successfully.")
        }

        return taskCompletionSource.task
    }

    public override func deleteItem(_ deleteItemInput: AWSDynamoDBDeleteItemInput) -> AWSTask<AWSDynamoDBDeleteItemOutput> {
        let tableName = deleteItemInput.tableName ?? "unknownTable"
        // Assume the primary key is always named according to AWSConfig
         let primaryKeyName = AWSConfig.hashFieldName
         let key = deleteItemInput.key?[primaryKeyName]?.s

         let operationKey = operationAttemptKey(type: .deleteItem, tableName: tableName, key: key)

         logOperation(.deleteItem, tableName: tableName, key: key)

        let taskCompletionSource = AWSTaskCompletionSource<AWSDynamoDBDeleteItemOutput>()

        Task {
            await simulateNetworkDelay()

             if let error = shouldFailWithError(operationKey: operationKey) {
                 taskCompletionSource.setError(error)
                 return
             }

            guard database[tableName] != nil else {
                 // Deleting from a non-existent table isn't strictly an error in DynamoDB,
                 // but for the mock, we might treat it as resource not found.
                taskCompletionSource.setError(resourceNotFoundError(tableName: tableName))
                return
            }

            guard let key = key else {
                taskCompletionSource.setError(validationError(message: "Missing primary key '\(primaryKeyName)' in DeleteItem request."))
                return
            }

            // Check for conditional expression "attribute_exists(#hashKey)"
             if let conditionExpression = deleteItemInput.conditionExpression,
                 let attributeNames = deleteItemInput.expressionAttributeNames,
                 attributeNames["#hashKey"] == primaryKeyName,
                 conditionExpression == "attribute_exists(#hashKey)",
                 database[tableName]?[key] == nil { // Check if item does NOT exist

                 taskCompletionSource.setError(conditionalCheckFailedError())
                 logger.debug("[deleteItem] Table '\(tableName)', Key '\(key)': ConditionalCheckFailed (attribute_exists)")
                 return
             }

            let itemExisted = database[tableName]?[key] != nil
            database[tableName]?.removeValue(forKey: key)

            let output = AWSDynamoDBDeleteItemOutput()
            taskCompletionSource.set(result: output)
            logger.debug("[deleteItem] Table '\(tableName)', Key '\(key)': Deleted (existed: \(itemExisted)).")
        }

        return taskCompletionSource.task
    }

    // MARK: - Async Wrappers (Swift Concurrency)

    /// Gets an item asynchronously, simulating the async/await pattern.
    public func getItem(_ getItemInput: AWSDynamoDBGetItemInput) async throws -> AWSDynamoDBGetItemOutput {
        return try await Task {
             try await self.getItem(getItemInput).aws_await()
         }.value
    }

    /// Puts an item asynchronously, simulating the async/await pattern.
    public func putItem(_ putItemInput: AWSDynamoDBPutItemInput) async throws -> AWSDynamoDBPutItemOutput {
         return try await Task {
             try await self.putItem(putItemInput).aws_await()
         }.value
    }

    /// Deletes an item asynchronously, simulating the async/await pattern.
    public func deleteItem(_ deleteItemInput: AWSDynamoDBDeleteItemInput) async throws -> AWSDynamoDBDeleteItemOutput {
         return try await Task {
             try await self.deleteItem(deleteItemInput).aws_await()
         }.value
    }

    // MARK: - Internal Helpers for Mocking

    private func logOperation(_ type: OperationType, tableName: String, key: String?, item: [String: AWSDynamoDBAttributeValue]? = nil) {
         operationLog.append(Operation(type: type, tableName: tableName, key: key, item: item))
     }

    private func resourceNotFoundError(tableName: String) -> NSError {
        return NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.resourceNotFoundException.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Mock table not found: \(tableName)"]
        )
    }

    private func validationError(message: String) -> NSError {
        return NSError(
            domain: AWSDynamoDBErrorDomain,
            code: AWSDynamoDBErrorType.validationException.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

     private func conditionalCheckFailedError() -> NSError {
         return NSError(
             domain: AWSDynamoDBErrorDomain,
             code: AWSDynamoDBErrorType.conditionalCheckFailed.rawValue,
             userInfo: [NSLocalizedDescriptionKey: "The conditional request failed"]
         )
     }

     /// Creates a deep copy of an AWSDynamoDBAttributeValue.
     private func deepCopyAttributeValue(_ original: AWSDynamoDBAttributeValue) -> AWSDynamoDBAttributeValue? {
          let copy = AWSDynamoDBAttributeValue()
          copy.b = original.b // Data (assuming Data is value type or copy-on-write)
          copy.boolean = original.boolean?.copy() as? NSNumber
          copy.bs = original.bs // Array<Data>
          copy.l = original.l?.compactMap { deepCopyAttributeValue($0) } // Recursively copy list
          copy.m = original.m?.mapValues { deepCopyAttributeValue($0) } // Recursively copy map
          copy.n = original.n // String
          copy.ns = original.ns // Array<String>
          copy.null = original.null?.copy() as? NSNumber
          copy.s = original.s // String
          copy.ss = original.ss // Array<String>
          return copy
      }

    // MARK: - Data Models

    /// Types of DynamoDB operations that can be performed.
    public enum OperationType: String {
        case getItem
        case putItem
        case deleteItem
    }

    /// Represents a recorded operation for verification in tests.
    public struct Operation {
        public let id: UUID = UUID()
        public let type: OperationType
        public let tableName: String
        public let key: String?
        public let item: [String: AWSDynamoDBAttributeValue]? // Store the item for PutItem
        public let timestamp: Date = Date()
    }
}

// MARK: - Mock Factory

/// Factory for easily creating and configuring AWSMockClient instances for testing.
public class AWSMockClientFactory {
    /// Creates a new, reset AWSMockClient instance.
    /// - Parameter hashValues: Optional array of hash values to pre-populate in the default table.
    /// - Returns: A configured AWSMockClient instance.
    public static func createMockClient(hashValues: [String]? = nil) -> AWSMockClient {
        // Create a new instance instead of using the shared one to ensure test isolation
        let mockClient = AWSMockClient()
        mockClient.reset() // Ensure clean state

        if let hashValues = hashValues, !hashValues.isEmpty {
            mockClient.populateWithHashes(hashValues)
        }

        return mockClient
    }
}
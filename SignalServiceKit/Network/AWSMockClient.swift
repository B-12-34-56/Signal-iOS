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
/// and provides methods to control behavior like delays and errors.
public class AWSMockClient: AWSDynamoDB {
    
    // MARK: - Singleton
    
    public static let shared = AWSMockClient()
    
    // MARK: - Properties
    
    /// Logger for capturing mock client operations
    private let logger = Logger(label: "org.signal.AWSMockClient")
    
    /// In-memory storage for mock database - simulates DynamoDB tables
    private var database: [String: [String: [String: AWSDynamoDBAttributeValue]]] = [:]
    
    /// Records all operations for verification in tests
    private var operationLog: [Operation] = []
    
    /// Configurable delay to simulate network latency
    private var simulatedDelay: TimeInterval = 0.0
    
    /// Controls whether operations should fail
    private var shouldFailOperations = false
    
    /// Custom error to return when operations fail
    private var customError: NSError?
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        setupDefaultTable()
    }
    
    private func setupDefaultTable() {
        // Create the default table that's used for content hash storage
        database[AWSConfig.dynamoDbTableName] = [:]
        logger.info("Created mock DynamoDB table: \(AWSConfig.dynamoDbTableName)")
    }
    
    // MARK: - Test Configuration Methods
    
    /// Resets the mock database and operation log to initial state
    public func reset() {
        database = [:]
        operationLog = []
        shouldFailOperations = false
        customError = nil
        simulatedDelay = 0.0
        setupDefaultTable()
        logger.info("Reset AWSMockClient to initial state")
    }
    
    /// Configure the mock to simulate network delays
    /// - Parameter seconds: The delay to add to operations in seconds
    public func setSimulatedDelay(_ seconds: TimeInterval) {
        simulatedDelay = seconds
        logger.info("Set simulated delay to \(seconds) seconds")
    }
    
    /// Configure the mock to fail operations
    /// - Parameters:
    ///   - shouldFail: Whether operations should fail
    ///   - error: Custom error to return, or nil to use default
    public func setFailureMode(shouldFail: Bool, error: NSError? = nil) {
        shouldFailOperations = shouldFail
        customError = error
        logger.info("Set failure mode to \(shouldFail)")
    }
    
    /// Populates the mock database with test data
    /// - Parameter hashValues: Array of hash values to add
    public func populateWithHashes(_ hashValues: [String]) {
        let tableName = AWSConfig.dynamoDbTableName
        
        for hash in hashValues {
            guard let hashAttr = AWSDynamoDBAttributeValue() else { continue }
            hashAttr.s = hash
            
            guard let timestampAttr = AWSDynamoDBAttributeValue() else { continue }
            timestampAttr.s = ISO8601DateFormatter().string(from: Date())
            
            guard let ttlAttr = AWSDynamoDBAttributeValue() else { continue }
            ttlAttr.n = String(Int(Date().timeIntervalSince1970) + (AWSConfig.defaultTTLInDays * 24 * 60 * 60))
            
            database[tableName]?[hash] = [
                AWSConfig.hashFieldName: hashAttr,
                AWSConfig.timestampFieldName: timestampAttr,
                AWSConfig.ttlFieldName: ttlAttr
            ]
        }
        
        logger.info("Populated database with \(hashValues.count) hash values")
    }
    
    /// Returns all operations performed since last reset
    /// - Returns: Array of operations
    public func getOperationLog() -> [Operation] {
        return operationLog
    }
    
    /// Returns count of operations by type
    /// - Parameter type: Operation type to count
    /// - Returns: Count of operations matching the type
    public func getOperationCount(type: OperationType) -> Int {
        return operationLog.filter { $0.type == type }.count
    }
    
    // MARK: - Helper Methods
    
    private func simulateNetworkDelay() async {
        if simulatedDelay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
            } catch {
                logger.debug("Sleep was interrupted during simulated delay")
            }
        }
    }
    
    private func shouldFailWithError() -> NSError? {
        if shouldFailOperations {
            return customError ?? NSError(
                domain: AWSDynamoDBErrorDomain,
                code: AWSDynamoDBErrorType.internalServerError.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Simulated failure in AWSMockClient"]
            )
        }
        return nil
    }
    
    // MARK: - AWSDynamoDB Method Implementations
    
    public override func getItem(_ getItemInput: AWSDynamoDBGetItemInput) -> AWSTask<AWSDynamoDBGetItemOutput> {
        let tableName = getItemInput.tableName!
        let hashFieldName = AWSConfig.hashFieldName
        
        operationLog.append(Operation(
            type: .getItem,
            tableName: tableName,
            key: getItemInput.key?[hashFieldName]?.s,
            timestamp: Date()
        ))
        
        let taskCompletionSource = AWSTaskCompletionSource<AWSDynamoDBGetItemOutput>()
        
        Task {
            await simulateNetworkDelay()
            
            if let error = shouldFailWithError() {
                taskCompletionSource.setError(error)
                return
            }
            
            guard let table = database[tableName] else {
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.resourceNotFoundException.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Table not found: \(tableName)"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            guard let key = getItemInput.key?[hashFieldName]?.s else {
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.validationException.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Missing hash key"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            let output = AWSDynamoDBGetItemOutput()
            output.item = table[key]
            
            taskCompletionSource.set(result: output)
            logger.debug("getItem: Returned item for key \(key)")
        }
        
        return taskCompletionSource.task
    }
    
    public override func putItem(_ putItemInput: AWSDynamoDBPutItemInput) -> AWSTask<AWSDynamoDBPutItemOutput> {
        let tableName = putItemInput.tableName!
        let hashFieldName = AWSConfig.hashFieldName
        
        let key = putItemInput.item?[hashFieldName]?.s
        
        operationLog.append(Operation(
            type: .putItem,
            tableName: tableName,
            key: key,
            timestamp: Date()
        ))
        
        let taskCompletionSource = AWSTaskCompletionSource<AWSDynamoDBPutItemOutput>()
        
        Task {
            await simulateNetworkDelay()
            
            if let error = shouldFailWithError() {
                taskCompletionSource.setError(error)
                return
            }
            
            guard let table = database[tableName] else {
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.resourceNotFoundException.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Table not found: \(tableName)"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            guard let item = putItemInput.item, let key = item[hashFieldName]?.s else {
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.validationException.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Missing hash key in item"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            // Check for conditional expression
            if let conditionExpression = putItemInput.conditionExpression,
               conditionExpression == "attribute_not_exists(#hashKey)",
               database[tableName]?[key] != nil {
                
                // Item already exists, return conditional check failed exception
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.conditionalCheckFailed.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "The conditional request failed"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            // Create a deep copy of the item to avoid reference issues
            var newItem: [String: AWSDynamoDBAttributeValue] = [:]
            for (attrKey, attrValue) in item {
                let newAttr = AWSDynamoDBAttributeValue()
                if attrValue.s != nil {
                    newAttr.s = attrValue.s
                } else if attrValue.n != nil {
                    newAttr.n = attrValue.n
                }
                newItem[attrKey] = newAttr
            }
            
            database[tableName]?[key] = newItem
            
            let output = AWSDynamoDBPutItemOutput()
            taskCompletionSource.set(result: output)
            logger.debug("putItem: Stored item with key \(key)")
        }
        
        return taskCompletionSource.task
    }
    
    public override func deleteItem(_ deleteItemInput: AWSDynamoDBDeleteItemInput) -> AWSTask<AWSDynamoDBDeleteItemOutput> {
        let tableName = deleteItemInput.tableName!
        let hashFieldName = AWSConfig.hashFieldName
        
        let key = deleteItemInput.key?[hashFieldName]?.s
        
        operationLog.append(Operation(
            type: .deleteItem,
            tableName: tableName,
            key: key,
            timestamp: Date()
        ))
        
        let taskCompletionSource = AWSTaskCompletionSource<AWSDynamoDBDeleteItemOutput>()
        
        Task {
            await simulateNetworkDelay()
            
            if let error = shouldFailWithError() {
                taskCompletionSource.setError(error)
                return
            }
            
            guard let table = database[tableName] else {
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.resourceNotFoundException.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Table not found: \(tableName)"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            guard let key = deleteItemInput.key?[hashFieldName]?.s else {
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.validationException.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Missing hash key"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            // Handle conditional expression if needed
            if let conditionExpression = deleteItemInput.conditionExpression,
               conditionExpression == "attribute_exists(#hashKey)",
               database[tableName]?[key] == nil {
                
                let error = NSError(
                    domain: AWSDynamoDBErrorDomain,
                    code: AWSDynamoDBErrorType.conditionalCheckFailed.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "The conditional request failed"]
                )
                taskCompletionSource.setError(error)
                return
            }
            
            database[tableName]?.removeValue(forKey: key)
            
            let output = AWSDynamoDBDeleteItemOutput()
            taskCompletionSource.set(result: output)
            logger.debug("deleteItem: Deleted item with key \(key ?? "unknown")")
        }
        
        return taskCompletionSource.task
    }
    
    // MARK: - Mocked async wrappers for Swift concurrency
    
    /// Gets an item asynchronously to match the Swift concurrency pattern used in the app
    public func getItem(_ getItemInput: AWSDynamoDBGetItemInput) async throws -> AWSDynamoDBGetItemOutput {
        return try await withCheckedThrowingContinuation { continuation in
            _ = self.getItem(getItemInput).continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: task.result!)
                }
                return nil
            }
        }
    }
    
    /// Puts an item asynchronously to match the Swift concurrency pattern used in the app
    public func putItem(_ putItemInput: AWSDynamoDBPutItemInput) async throws -> AWSDynamoDBPutItemOutput {
        return try await withCheckedThrowingContinuation { continuation in
            _ = self.putItem(putItemInput).continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: task.result!)
                }
                return nil
            }
        }
    }
    
    /// Deletes an item asynchronously to match the Swift concurrency pattern used in the app
    public func deleteItem(_ deleteItemInput: AWSDynamoDBDeleteItemInput) async throws -> AWSDynamoDBDeleteItemOutput {
        return try await withCheckedThrowingContinuation { continuation in
            _ = self.deleteItem(deleteItemInput).continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: task.result!)
                }
                return nil
            }
        }
    }
    
    // MARK: - Data Models
    
    /// Types of DynamoDB operations that can be performed
    public enum OperationType: String {
        case getItem
        case putItem
        case deleteItem
    }
    
    /// Represents a recorded operation for verification in tests
    public struct Operation {
        public let id: UUID = UUID()
        public let type: OperationType
        public let tableName: String
        public let key: String?
        public let timestamp: Date
    }
}

// MARK: - Mock Factory

/// Factory for easily creating AWS mock clients for testing
public class AWSMockClientFactory {
    /// Creates a pre-configured AWSMockClient
    /// - Parameter hashValues: Optional array of hash values to pre-populate
    /// - Returns: Configured AWSMockClient
    public static func createMockClient(hashValues: [String]? = nil) -> AWSMockClient {
        let mockClient = AWSMockClient.shared
        mockClient.reset()
        
        if let hashValues = hashValues, !hashValues.isEmpty {
            mockClient.populateWithHashes(hashValues)
        }
        
        return mockClient
    }
}
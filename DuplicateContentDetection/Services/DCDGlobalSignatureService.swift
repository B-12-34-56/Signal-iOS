//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSDynamoDB
import Logging
import SignalCore

/// Manages global content hash signature checks and storage in DynamoDB
public final class GlobalSignatureService {
    // MARK: - Singleton
    
    /// Shared instance for accessing the service throughout the app
    public static let shared = GlobalSignatureService()
    
    // MARK: - Private Properties
    
    /// DynamoDB client for interacting with AWS
    private let client: AWSDynamoDB
    
    /// Logger for capturing service operations
    private let logger = Logger(label: "org.signal.GlobalSignatureService")
    
    /// Table name from AWSConfig
    private let tableName = AWSConfig.dynamoDbTableName
    
    /// Field names from AWSConfig
    private let hashFieldName = AWSConfig.hashFieldName
    private let timestampFieldName = AWSConfig.timestampFieldName
    private let ttlFieldName = AWSConfig.ttlFieldName
    
    /// Default retry count for operations
    private let defaultRetryCount = 3
    
    // MARK: - Initialization
    
    /// Private initializer for singleton
    private init() {
        // Get the configured DynamoDB client from AWSConfig
        client = AWSConfig.getDynamoDBClient()
        logger.info("Initialized GlobalSignatureService with DynamoDB client.")
        SignalCoreUtility.logDebug("Initialized GlobalSignatureService with DynamoDB client.")
    }
    
    // MARK: - Helper Methods
    
    /// Creates a DynamoDB attribute value for a string.
    /// - Parameter value: The string value to convert
    /// - Returns: An AWSDynamoDBAttributeValue or nil if creation fails
    private func createStringAttributeValue(_ value: String) -> AWSDynamoDBAttributeValue? {
        guard let attributeValue = AWSDynamoDBAttributeValue() else {
            logger.error("Failed to create AWSDynamoDBAttributeValue for String.")
            SignalCoreUtility.logError("Failed to create AWSDynamoDBAttributeValue for String.")
            return nil
        }
        attributeValue.s = value
        return attributeValue
    }
    
    /// Creates a DynamoDB attribute value for a number (represented as a string).
    /// - Parameter value: The integer value to convert
    /// - Returns: An AWSDynamoDBAttributeValue or nil if creation fails
    private func createNumberAttributeValue(_ value: Int) -> AWSDynamoDBAttributeValue? {
        guard let attributeValue = AWSDynamoDBAttributeValue() else {
            logger.error("Failed to create AWSDynamoDBAttributeValue for Number.")
            SignalCoreUtility.logError("Failed to create AWSDynamoDBAttributeValue for Number.")
            return nil
        }
        // DynamoDB expects numbers as strings for the 'N' type via the SDK
        attributeValue.n = String(value)
        return attributeValue
    }
    
    /// Calculates the TTL timestamp (Unix epoch) based on the configured duration.
    /// - Returns: Unix timestamp for TTL expiration
    private func calculateTTLTimestamp() -> Int {
        let currentDate = Date()
        return Int(currentDate.timeIntervalSince1970) + (AWSConfig.defaultTTLInDays * 24 * 60 * 60)
    }
    
    /// Checks if an NSError from AWS SDK is retryable.
    /// - Parameter error: The error to check
    /// - Returns: Boolean indicating whether the error is retryable
    private func isRetryableAWSError(_ error: NSError) -> Bool {
        // Consider throttling, provisional throughput exceeded, and general service errors as retryable
        if error.domain == AWSServiceErrorDomain {
            switch AWSServiceErrorType(rawValue: error.code) {
            case .throttling, .requestTimeout, .serviceUnavailable, .internalFailure:
                return true
            default:
                return false
            }
        }
        
        if error.domain == AWSDynamoDBErrorDomain {
            switch AWSDynamoDBErrorType(rawValue: error.code) {
            case .throttlingException, .provisionedThroughputExceededException, 
                 .requestLimitExceeded, .internalServerError:
                return true
            default:
                return false
            }
        }
        
        // Network connection errors are also retryable
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return true
            default:
                return false
            }
        }
        
        // Default to non-retryable for unknown errors
        return false
    }
    
    // MARK: - Public API
    
    /// Checks if a content hash exists in the DynamoDB database with retry logic.
    /// - Parameters:
    ///   - hash: The content hash to check (Base64 encoded)
    ///   - retryCount: Optional maximum number of attempts, defaults to class default
    /// - Returns: Boolean indicating whether the hash exists. Returns `false` on persistent error.
    public func contains(_ hash: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        guard let input = AWSDynamoDBGetItemInput() else {
            logger.error("[Contains] Failed to create GetItemInput for hash check: \(hash.prefix(8))")
            return false
        }
        
        input.tableName = tableName
        
        guard let hashAttr = createStringAttributeValue(hash) else {
            logger.error("[Contains] Failed to create hash AttributeValue for hash check: \(hash.prefix(8))")
            return false
        }
        
        input.key = [hashFieldName: hashAttr]
        
        // Request only the primary key to minimize data transfer
        input.projectionExpression = "#hashKey"
        input.expressionAttributeNames = ["#hashKey": hashFieldName]
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[Contains] Attempt \(attempt + 1)/\(maxAttempts) to check hash \(hash.prefix(8))")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                let output = try await withCheckedThrowingContinuation { continuation in
                    _ = client.getItem(input).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                let found = output.item != nil && !output.item!.isEmpty
                logger.info("[Contains] Successfully checked hash \(hash.prefix(8)): \(found)")
                return found
                
            } catch let error as NSError {
                logger.warning("[Contains] DynamoDB getItem failed for hash \(hash.prefix(8)) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription), Code: \(error.code), Domain: \(error.domain)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[Contains] DynamoDB getItem failed after \(attempt + 1) attempts for hash \(hash.prefix(8)). Will not retry.")
                    return false // exhausted retries or non-retryable error
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                logger.info("[Contains] Retrying DynamoDB getItem for hash \(hash.prefix(8)) after \(String(format: "%.2f", delay)) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[Contains] An unexpected error occurred during DynamoDB getItem for hash \(hash.prefix(8)) (attempt \(attempt + 1)/\(maxAttempts)): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return false
                }
                
                // Apply backoff for unexpected errors too
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[Contains] Reached end of contains function unexpectedly for hash \(hash.prefix(8)).")
        return false
    }
    
    /// Stores a content hash in the DynamoDB database with retry logic and idempotency.
    /// - Parameters:
    ///   - hash: The content hash to store (Base64 encoded)
    ///   - retryCount: Optional maximum number of attempts, defaults to class default
    /// - Returns: A boolean indicating success (includes case where item already existed)
    @discardableResult
    public func store(_ hash: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        guard let input = AWSDynamoDBPutItemInput() else {
            logger.error("[Store] Failed to create PutItemInput for hash store: \(hash.prefix(8))")
            return false
        }
        
        input.tableName = tableName
        
        // Current timestamp in ISO8601 format
        let currentDate = Date()
        let timestampString = ISO8601DateFormatter().string(from: currentDate)
        
        // Calculate TTL timestamp for automatic expiration
        let ttlTimestampValue = calculateTTLTimestamp()
        
        // Create the attribute values
        guard let hashAttr = createStringAttributeValue(hash),
              let timestampAttr = createStringAttributeValue(timestampString),
              let ttlAttr = createNumberAttributeValue(ttlTimestampValue) else {
            logger.error("[Store] Failed to create one or more AttributeValues for hash store: \(hash.prefix(8))")
            return false
        }
        
        // Create item with hash, timestamp, and TTL attributes
        input.item = [
            hashFieldName: hashAttr,
            timestampFieldName: timestampAttr,
            ttlFieldName: ttlAttr
        ]
        
        // Use condition expression to only insert if the item doesn't already exist (ensures idempotency)
        input.conditionExpression = "attribute_not_exists(#hashKey)"
        input.expressionAttributeNames = ["#hashKey": hashFieldName]
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[Store] Attempt \(attempt + 1)/\(maxAttempts) to store hash \(hash.prefix(8))")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                _ = try await withCheckedThrowingContinuation { continuation in
                    _ = client.putItem(input).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                logger.info("[Store] Successfully stored hash \(hash.prefix(8)) in DynamoDB.")
                return true // Success
                
            } catch let error as NSError {
                // Check specifically for ConditionalCheckFailedException (means item already exists - considered success for idempotency)
                if error.domain == AWSDynamoDBErrorDomain, error.code == AWSDynamoDBErrorType.conditionalCheckFailed.rawValue {
                    logger.info("[Store] Hash \(hash.prefix(8)) already exists in DynamoDB (ConditionalCheckFailedException). Considered successful.")
                    return true // Item already exists, which is fine for idempotency
                }
                
                logger.warning("[Store] DynamoDB putItem failed for hash \(hash.prefix(8)) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription), Code: \(error.code), Domain: \(error.domain)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[Store] DynamoDB putItem failed after \(attempt + 1) attempts for hash \(hash.prefix(8)). Will not retry.")
                    return false // exhausted retries or non-retryable error
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                logger.info("[Store] Retrying DynamoDB putItem for hash \(hash.prefix(8)) after \(String(format: "%.2f", delay)) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[Store] An unexpected error occurred during DynamoDB putItem for hash \(hash.prefix(8)) (attempt \(attempt + 1)/\(maxAttempts)): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return false
                }
                
                // Apply backoff for unexpected errors too
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[Store] Reached end of store function unexpectedly for hash \(hash.prefix(8)).")
        return false
    }
    
    /// Deletes a content hash from the DynamoDB database with retry logic.
    /// - Parameters:
    ///   - hash: The content hash to delete (Base64 encoded)
    ///   - retryCount: Optional maximum number of attempts, defaults to class default
    /// - Returns: A boolean indicating success
    @discardableResult
    public func delete(_ hash: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        guard let input = AWSDynamoDBDeleteItemInput() else {
            logger.error("[Delete] Failed to create DeleteItemInput for hash delete: \(hash.prefix(8))")
            return false
        }
        
        input.tableName = tableName
        
        guard let hashAttr = createStringAttributeValue(hash) else {
            logger.error("[Delete] Failed to create hash AttributeValue for hash delete: \(hash.prefix(8))")
            return false
        }
        
        input.key = [hashFieldName: hashAttr]
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[Delete] Attempt \(attempt + 1)/\(maxAttempts) to delete hash \(hash.prefix(8))")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                _ = try await withCheckedThrowingContinuation { continuation in
                    _ = client.deleteItem(input).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                logger.info("[Delete] Successfully deleted hash \(hash.prefix(8)) from DynamoDB (if it existed).")
                return true // Success
                
            } catch let error as NSError {
                logger.warning("[Delete] DynamoDB deleteItem failed for hash \(hash.prefix(8)) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription), Code: \(error.code), Domain: \(error.domain)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[Delete] DynamoDB deleteItem failed after \(attempt + 1) attempts for hash \(hash.prefix(8)). Will not retry.")
                    return false // exhausted retries or non-retryable error
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                logger.info("[Delete] Retrying DynamoDB deleteItem for hash \(hash.prefix(8)) after \(String(format: "%.2f", delay)) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[Delete] An unexpected error occurred during DynamoDB deleteItem for hash \(hash.prefix(8)) (attempt \(attempt + 1)/\(maxAttempts)): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return false
                }
                
                // Apply backoff for unexpected errors too
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[Delete] Reached end of delete function unexpectedly for hash \(hash.prefix(8)).")
        return false
    }
} 
//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSLambda
import Logging
import CryptoKit

/// Manages interactions with AWS Lambda for content processing and analysis
public final class LambdaService {
    // MARK: - Singleton
    
    /// Shared instance for accessing the service throughout the app
    public static let shared = LambdaService()
    
    // MARK: - Constants
    
    /// The name of the Lambda function for content processing
    public let contentProcessorFunctionName = "signal-content-processor"
    
    /// The AWS region for the Lambda service
    public let lambdaRegion = AWSRegionType.USWest2
    
    /// Default timeout for Lambda invocations (in seconds)
    public let defaultInvocationTimeout: TimeInterval = 30.0
    
    /// Default retry count for Lambda operations
    public let defaultRetryCount = 3
    
    // MARK: - Private Properties
    
    /// Lambda client for interacting with AWS
    private let client: AWSLambda
    
    /// Logger for capturing service operations
    private let logger = Logger(label: "org.signal.LambdaService")
    
    // MARK: - Initialization
    
    /// Private initializer for singleton
    private init() {
        // Ensure AWS credentials are set up
        if AWSServiceManager.default().defaultServiceConfiguration == nil {
            AWSConfig.setupAWSCredentials()
        }
        
        // Configure Lambda client with custom settings
        let lambdaConfiguration = AWSServiceConfiguration(
            region: lambdaRegion,
            credentialsProvider: AWSServiceManager.default().defaultServiceConfiguration?.credentialsProvider
        )
        
        // Register Lambda with the custom configuration
        AWSLambda.register(with: lambdaConfiguration!, forKey: "DefaultLambda")
        
        // Get the client instance
        if let client = AWSLambda(forKey: "DefaultLambda") {
            self.client = client
        } else {
            self.client = AWSLambda.default()
            logger.warning("Using default Lambda client configuration")
        }
        
        logger.info("Initialized LambdaService with function: \(contentProcessorFunctionName)")
    }
    
    // MARK: - Public API: Content Processing
    
    /// Invokes the content processing Lambda function for image analysis
    /// - Parameters:
    ///   - imageData: The image data to process
    ///   - metadata: Additional metadata for the processing request
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: Processing result or nil if processing fails
    public func processImage(imageData: Data, metadata: [String: Any], retryCount: Int? = nil) async -> ContentProcessingResult? {
        let maxAttempts = retryCount ?? defaultRetryCount
        
        // Create request payload
        guard let payload = createImageProcessingPayload(imageData: imageData, metadata: metadata) else {
            logger.error("[ProcessImage] Failed to create payload for Lambda invocation")
            return nil
        }
        
        return await invokeLambdaFunction(
            functionName: contentProcessorFunctionName,
            payload: payload,
            maxAttempts: maxAttempts
        )
    }
    
    /// Processes an attachment through Lambda using its S3 location
    /// - Parameters:
    ///   - s3Key: The S3 key where the attachment is stored
    ///   - metadata: Additional metadata for the processing request
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: Processing result or nil if processing fails
    public func processAttachmentFromS3(s3Key: String, metadata: [String: Any], retryCount: Int? = nil) async -> ContentProcessingResult? {
        let maxAttempts = retryCount ?? defaultRetryCount
        
        // Create request payload for S3-based processing
        guard let payload = createS3ProcessingPayload(s3Key: s3Key, metadata: metadata) else {
            logger.error("[ProcessS3] Failed to create S3 payload for Lambda invocation")
            return nil
        }
        
        return await invokeLambdaFunction(
            functionName: contentProcessorFunctionName,
            payload: payload,
            maxAttempts: maxAttempts
        )
    }
    
    /// Checks content hash against known patterns for harmful content
    /// - Parameters:
    ///   - hash: The content hash to validate
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: Validation result or nil if validation fails
    public func validateContentHash(_ hash: String, retryCount: Int? = nil) async -> ContentValidationResult? {
        let maxAttempts = retryCount ?? defaultRetryCount
        
        // Create request payload for hash validation
        guard let payload = createHashValidationPayload(hash: hash) else {
            logger.error("[ValidateHash] Failed to create hash validation payload")
            return nil
        }
        
        return await invokeLambdaFunction(
            functionName: contentProcessorFunctionName,
            payload: payload,
            maxAttempts: maxAttempts
        )
    }
    
    // MARK: - Private Helper Methods
    
    /// Invokes a Lambda function with retry logic
    /// - Parameters:
    ///   - functionName: The name of the function to invoke
    ///   - payload: The function payload
    ///   - maxAttempts: Maximum number of retry attempts
    /// - Returns: Result of the Lambda invocation or nil on failure
    private func invokeLambdaFunction<T: Decodable>(
        functionName: String,
        payload: [String: Any],
        maxAttempts: Int
    ) async -> T? {
        // Create Lambda invocation request
        guard let invocationRequest = AWSLambdaInvocationRequest() else {
            logger.error("[InvokeLambda] Failed to create Lambda invocation request")
            return nil
        }
        
        // Configure the request
        invocationRequest.functionName = functionName
        invocationRequest.invocationType = .requestResponse // Synchronous invocation
        
        // Serialize the payload to JSON
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
            invocationRequest.payload = jsonData
        } catch {
            logger.error("[InvokeLambda] Failed to serialize payload: \(error.localizedDescription)")
            return nil
        }
        
        // Attempt to invoke the function with retries
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[InvokeLambda] Attempt \(attempt + 1)/\(maxAttempts) to invoke Lambda function: \(functionName)")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                let response = try await withCheckedThrowingContinuation { continuation in
                    client.invoke(invocationRequest).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                // Check for function errors
                if let functionError = response.functionError {
                    logger.error("[InvokeLambda] Lambda function returned error: \(functionError)")
                    if attempt < maxAttempts - 1 {
                        // Apply exponential backoff with jitter for retryable function errors
                        let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    return nil
                }
                
                // Process the response payload
                guard let payload = response.payload else {
                    logger.error("[InvokeLambda] Lambda function returned empty response")
                    return nil
                }
                
                // Deserialize the response
                do {
                    let result = try JSONDecoder().decode(T.self, from: payload)
                    logger.info("[InvokeLambda] Successfully invoked Lambda function: \(functionName)")
                    return result
                } catch {
                    logger.error("[InvokeLambda] Failed to parse Lambda response: \(error.localizedDescription)")
                    return nil
                }
                
            } catch let error as NSError {
                logger.warning("[InvokeLambda] Lambda invocation failed (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                
                // Check if the error is retryable
                guard isRetryableLambdaError(error), attempt < maxAttempts - 1 else {
                    logger.error("[InvokeLambda] Lambda invocation failed after \(attempt + 1) attempts. Will not retry.")
                    return nil
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                logger.info("[InvokeLambda] Retrying Lambda invocation after \(String(format: "%.2f", delay)) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[InvokeLambda] Unexpected error during Lambda invocation: \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return nil
                }
                
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[InvokeLambda] Exhausted all retry attempts for Lambda function: \(functionName)")
        return nil
    }
    
    /// Creates a payload for image processing requests
    /// - Parameters:
    ///   - imageData: The image data to process
    ///   - metadata: Additional metadata for the processing request
    /// - Returns: Payload dictionary or nil if creation fails
    private func createImageProcessingPayload(imageData: Data, metadata: [String: Any]) -> [String: Any]? {
        // Calculate image hash for integrity verification
        let hash = SHA256.hash(data: imageData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        // Create a Base64 encoded string of the image data
        let base64EncodedImage = imageData.base64EncodedString()
        
        // Build the payload
        var payload: [String: Any] = [
            "requestType": "imageProcessing",
            "image": [
                "data": base64EncodedImage,
                "hash": hashString,
                "size": imageData.count
            ]
        ]
        
        // Add metadata
        payload["metadata"] = metadata
        
        return payload
    }
    
    /// Creates a payload for S3-based processing requests
    /// - Parameters:
    ///   - s3Key: The S3 key where the attachment is stored
    ///   - metadata: Additional metadata for the processing request
    /// - Returns: Payload dictionary or nil if creation fails
    private func createS3ProcessingPayload(s3Key: String, metadata: [String: Any]) -> [String: Any]? {
        // Build the payload
        var payload: [String: Any] = [
            "requestType": "s3Processing",
            "s3": [
                "bucket": "signal-content-attachments",
                "key": s3Key
            ]
        ]
        
        // Add metadata
        payload["metadata"] = metadata
        
        return payload
    }
    
    /// Creates a payload for hash validation requests
    /// - Parameter hash: The content hash to validate
    /// - Returns: Payload dictionary or nil if creation fails
    private func createHashValidationPayload(hash: String) -> [String: Any]? {
        // Build the payload
        let payload: [String: Any] = [
            "requestType": "hashValidation",
            "hash": hash
        ]
        
        return payload
    }
    
    /// Checks if a Lambda error is retryable
    /// - Parameter error: The error to check
    /// - Returns: Boolean indicating if the error is retryable
    private func isRetryableLambdaError(_ error: NSError) -> Bool {
        // Lambda-specific error codes
        if error.domain == AWSLambdaErrorDomain {
            switch AWSLambdaErrorType(rawValue: error.code) {
            case .serviceException, .tooManyRequestsException, .ec2ThrottledException,
                 .ec2UnexpectedException, .resourceNotReadyException:
                return true
            default:
                return false
            }
        }
        
        // General AWS service errors
        if error.domain == AWSServiceErrorDomain {
            switch AWSServiceErrorType(rawValue: error.code) {
            case .throttling, .requestTimeout, .serviceUnavailable, .internalFailure:
                return true
            default:
                return false
            }
        }
        
        // Network connection errors
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
}

// MARK: - Response Types

/// Result of content processing operations
public struct ContentProcessingResult: Codable {
    /// Whether the processing was successful
    public let success: Bool
    
    /// The processing status
    public let status: String
    
    /// The content hash if available
    public let contentHash: String?
    
    /// Any detected issues with the content
    public let detectedIssues: [String]?
    
    /// Confidence score for the results (0-100)
    public let confidenceScore: Double?
    
    /// Additional result data
    public let resultData: [String: String]?
    
    /// Error message if unsuccessful
    public let errorMessage: String?
}

/// Result of content validation operations
public typealias ContentValidationResult = ContentProcessingResult
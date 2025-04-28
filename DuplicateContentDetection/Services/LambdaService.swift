//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSLambda
import Logging
import CryptoKit
import DuplicateContentDetection // Ensure tracker is accessible

/// Manages interactions with AWS Lambda for content processing and analysis,
/// including image processing, S3 attachment processing, and hash validation.
/// Configured via values conceptually derived from `aws-config.json` through `AWSConfig`.
public final class LambdaService {
    // MARK: - Singleton

    /// Shared instance for accessing the service throughout the app.
    public static let shared = LambdaService()

    // MARK: - Types

    /// Represents the status of a batch import job.
    public struct JobStatus: Codable {
        public enum Status: String, Codable {
            case pending, processing, completed, failed, cancelled
        }

        public let jobId: String
        public let status: Status // Our local enum
        public let progress: Double
        public let errorMessage: String?
        public let createdAt: Date
        public var updatedAt: Date

        // Initializer for mapping from BatchImportJobTracker.JobStatusData
        init(trackerStatus: BatchImportJobTracker.JobStatusData) {
             self.jobId = trackerStatus.jobId
             // Explicitly map status enum
             self.status = JobStatus.Status(rawValue: trackerStatus.status.rawValue) ?? .failed
             self.progress = trackerStatus.progress
             self.errorMessage = trackerStatus.errorMessage
             self.createdAt = trackerStatus.createdAt
             self.updatedAt = trackerStatus.updatedAt
        }
    }

    // MARK: - Constants

    /// The name of the Lambda function for content processing, fetched from configuration.
    /// Corresponds to `aws.lambda.functions.contentProcessor.name` in `aws-config.json`.
    public let contentProcessorFunctionName = "signal-content-processor"

    /// The ARN of the Lambda function for S3 to DynamoDB batch imports.
    /// Corresponds to `aws.lambda.functions.s3ToDynamoDB.arn` in `aws-config.json`.
    public let s3ToDynamoDbFunctionArn = "arn:aws:lambda:us-east-1:739874238091:function:S3toDynamo"

    /// The AWS region for the Lambda service. Should match AWSConfig region.
    /// Corresponds to the region used in `aws-config.json` for Lambda, assumed same as Cognito/DynamoDB.
    public let lambdaRegion = AWSConfig.cognitoRegion // Use consistent region

    /// Default timeout for Lambda invocations (in seconds). Can be overridden per request if needed.
    /// Corresponds to `aws.lambda.functions.contentProcessor.timeout`.
    public let defaultInvocationTimeout: TimeInterval = 30.0

    /// Default number of times to retry failed Lambda operations.
    public let defaultRetryCount = AWSConfig.maxRetryCount

    // MARK: - Private Properties

    /// Lambda client for interacting with AWS, configured via AWSConfig.
    private let client: AWSLambda

    /// Logger for capturing service operations and errors.
    private let logger = Logger(label: "org.signal.LambdaService")

    /// Set to keep track of ongoing invocation identifiers (e.g., correlation IDs).
    /// Used for basic tracking, not cancellation in this implementation.
    private var ongoingInvocations = Set<UUID>()
    private let trackingLock = NSLock()

    // MARK: - Initialization

    /// Private initializer for singleton pattern. Configures the Lambda client.
    private init() {
        // Ensure AWS credentials are set up via AWSConfig.
        if AWSServiceManager.default().defaultServiceConfiguration == nil {
            AWSConfig.setupAWSCredentials()
        }

        // Configure Lambda client with appropriate region and credentials.
        let lambdaConfiguration = AWSServiceConfiguration(
            region: lambdaRegion,
            credentialsProvider: AWSServiceManager.default().defaultServiceConfiguration?.credentialsProvider
        )

        // Register Lambda client with a specific key.
        AWSLambda.register(with: lambdaConfiguration!, forKey: "CustomLambdaClient")

        // Retrieve the registered client.
        if let specificClient = AWSLambda(forKey: "CustomLambdaClient") {
            self.client = specificClient
        } else {
            // Fallback to default if registration fails.
            self.client = AWSLambda.default()
            logger.warning("Using default Lambda client configuration as custom registration failed.")
        }

        logger.info("Initialized LambdaService for region \(lambdaRegion.stringValue) and function: \(contentProcessorFunctionName)")
    }

    // MARK: - Public API: Content Processing

    /// Invokes the content processing Lambda function asynchronously for image analysis.
    /// - Parameters:
    ///   - imageData: The image `Data` to process.
    ///   - metadata: Additional `[String: Any]` metadata for the processing request.
    ///   - invocationType: The type of Lambda invocation (.requestResponse or .event). Defaults to `.requestResponse`.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    /// - Returns: `ContentProcessingResult` if invocation type is `.requestResponse` and successful, `nil` otherwise or on failure.
    @discardableResult
    public func processImage(
        imageData: Data,
        metadata: [String: Any],
        invocationType: AWSLambdaInvocationType = .requestResponse,
        retryCount: Int? = nil
    ) async -> ContentProcessingResult? {
        let operationType = "ProcessImage"
        guard let payload = createImageProcessingPayload(imageData: imageData, metadata: metadata) else {
            logger.error("[\(operationType)] Failed to create payload.")
            return nil
        }

        return await invokeLambdaFunction(
            functionName: contentProcessorFunctionName,
            payload: payload,
            invocationType: invocationType,
            maxAttempts: retryCount ?? defaultRetryCount
        )
    }

    /// Invokes the content processing Lambda function asynchronously using an S3 key.
    /// - Parameters:
    ///   - s3Key: The S3 object key where the attachment is stored.
    ///   - metadata: Additional `[String: Any]` metadata for the processing request.
    ///   - invocationType: The type of Lambda invocation (.requestResponse or .event). Defaults to `.requestResponse`.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    /// - Returns: `ContentProcessingResult` if invocation type is `.requestResponse` and successful, `nil` otherwise or on failure.
    @discardableResult
    public func processAttachmentFromS3(
        s3Key: String,
        metadata: [String: Any],
        invocationType: AWSLambdaInvocationType = .requestResponse,
        retryCount: Int? = nil
    ) async -> ContentProcessingResult? {
        let operationType = "ProcessS3Attachment"
        // Assumes aws-config.json specifies the bucket name used by the Lambda.
        let bucketName = "signal-content-attachments" // Fetch dynamically if needed
        guard let payload = createS3ProcessingPayload(bucket: bucketName, key: s3Key, metadata: metadata) else {
            logger.error("[\(operationType)] Failed to create S3 payload.")
            return nil
        }

        return await invokeLambdaFunction(
            functionName: contentProcessorFunctionName,
            payload: payload,
            invocationType: invocationType,
            maxAttempts: retryCount ?? defaultRetryCount
        )
    }

    /// Invokes the Lambda function to validate a content hash.
    /// - Parameters:
    ///   - hash: The Base64 encoded content hash string to validate.
    ///   - invocationType: The type of Lambda invocation (.requestResponse or .event). Defaults to `.requestResponse`.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    /// - Returns: `ContentValidationResult` if invocation type is `.requestResponse` and successful, `nil` otherwise or on failure.
    @discardableResult
    public func validateContentHash(
        _ hash: String,
        invocationType: AWSLambdaInvocationType = .requestResponse,
        retryCount: Int? = nil
    ) async -> ContentValidationResult? {
        let operationType = "ValidateHash"
        guard let payload = createHashValidationPayload(hash: hash) else {
            logger.error("[\(operationType)] Failed to create hash validation payload.")
            return nil
        }

        return await invokeLambdaFunction(
            functionName: contentProcessorFunctionName,
            payload: payload,
            invocationType: invocationType,
            maxAttempts: retryCount ?? defaultRetryCount
        )
    }

    // MARK: - Public API: S3 to DynamoDB Transfer

    /// Triggers the Lambda function responsible for importing hash data from an S3 file into DynamoDB.
    /// - Parameters:
    ///   - s3BucketName: The name of the S3 bucket containing the hash file.
    ///   - s3Key: The S3 object key of the hash file (e.g., CSV or JSON).
    ///   - metadata: Optional metadata to pass to the Lambda function.
    ///   - invocationType: The type of Lambda invocation (.requestResponse or .event). Defaults to `.event` for batch jobs.
    ///   - retryCount: Optional number of retry attempts.
    /// - Returns: A `S3TransferResponse` containing the job ID if the invocation was successful (for `.requestResponse`),
    ///            or a simple success indicator (Bool) for `.event`, or `nil` on failure.
    @discardableResult
    public func triggerS3toDynamoDBTransfer<T: Decodable>(
        s3BucketName: String,
        s3Key: String,
        metadata: [String: Any]? = nil,
        invocationType: AWSLambdaInvocationType = .event, // Default to async for batch jobs
        retryCount: Int? = nil
    ) async -> T? {
        let operationType = "TriggerS3ToDynamoTransfer"
        let maxAttempts = retryCount ?? defaultRetryCount

        // Create the payload for the S3toDynamo Lambda function.
        // This structure depends on what the Lambda function expects.
        var payload: [String: Any] = [
            "sourceBucket": s3BucketName,
            "sourceKey": s3Key,
            "destinationTable": AWSConfig.dynamoDbTableName // Assuming Lambda needs the table name
        ]
        if let metadata = metadata {
            payload["metadata"] = metadata // Include optional metadata
        }

        logger.info("[\(operationType)] Triggering Lambda function \(s3ToDynamoDbFunctionArn) for S3 object: s3://\(s3BucketName)/\(s3Key)")

        // Invoke the specific S3toDynamoDB Lambda function by its ARN.
        // The expected return type `T` depends on the invocation type.
        // For .event, we might expect `Bool` (submission success).
        // For .requestResponse, we might expect `S3TransferResponse`.
        return await invokeLambdaFunction(
            functionName: s3ToDynamoDbFunctionArn, // Use the specific ARN
            payload: payload,
            invocationType: invocationType,
            maxAttempts: maxAttempts
        )
    }

    /// Checks the status of an S3 to DynamoDB batch transfer job using the BatchImportJobTracker.
    /// - Parameter jobId: The unique job ID returned when the transfer was triggered.
    /// - Returns: The current `JobStatus` or `nil` if the job is not found or an error occurs.
    public func checkS3ToDynamoDBTransferStatus(jobId: String) async -> JobStatus? {
        let operationType = "CheckS3TransferStatus"
        logger.info("[\(operationType)] Checking status for S3 to DynamoDB transfer job ID: \(jobId)")

        // Use the BatchImportJobTracker service to get the job status.
        // This assumes BatchImportJobTracker is available and has a getStatus method.
        do {
            guard let trackerStatus = try? await BatchImportJobTracker.shared.getStatus(for: jobId) else {
                logger.warning("[\(operationType)] Job ID \(jobId) not found in tracker.")
                return nil
            }

            // Map the tracker's internal status data to the public JobStatus struct
            // Ensure JobStatus has an appropriate initializer or direct mapping works
            let jobStatus = JobStatus(
                jobId: trackerStatus.jobId,
                status: JobStatus.Status(rawValue: trackerStatus.status.rawValue) ?? .failed, // Example explicit mapping
                progress: trackerStatus.progress,
                errorMessage: trackerStatus.errorMessage,
                createdAt: trackerStatus.createdAt,
                updatedAt: trackerStatus.updatedAt
            )
            logger.info("[\(operationType)] Status for job \(jobId): \(jobStatus.status.rawValue), Progress: \(jobStatus.progress)")
            return jobStatus

        } catch {
            logger.error("[\(operationType)] Error checking status for job \(jobId): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private Helper Methods

    /// Invokes a Lambda function with specified payload, invocation type, and retry logic.
    /// Tracks ongoing invocations using a UUID.
    private func invokeLambdaFunction<T: Decodable>(
        functionName: String,
        payload: [String: Any],
        invocationType: AWSLambdaInvocationType,
        maxAttempts: Int
    ) async -> T? {
        let invocationId = UUID() // Unique ID for tracking this specific invocation attempt chain
        trackInvocationStart(id: invocationId)
        defer { trackInvocationEnd(id: invocationId) }

        let operationType = "InvokeLambda"

        guard let invocationRequest = AWSLambdaInvocationRequest() else {
            logger.error("[\(operationType)] Failed to create Lambda invocation request. ID: \(invocationId)")
            return nil
        }

        invocationRequest.functionName = functionName
        invocationRequest.invocationType = invocationType // Use the passed invocation type
        // Client context can be added here if needed for Lambda context
        // invocationRequest.clientContext = ...

        // Serialize payload to JSON Data.
        do {
            invocationRequest.payload = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.error("[\(operationType)] Failed to serialize payload: \(error.localizedDescription). ID: \(invocationId)")
            return nil
        }

        // Use helper to execute with retry logic.
        let result: Result<AWSLambdaInvocationResponse, Error> = await executeWithRetry(
            maxAttempts: maxAttempts,
            operationType: operationType,
            key: invocationId.uuidString // Use UUID string as key for logging
        ) {
             // This is the actual operation performed inside the retry loop
             logger.debug("Invoking Lambda function '\(functionName)' (Type: \(invocationType.rawValue))...")
             return try await self.client.invoke(invocationRequest).aws_await()
        }

        // Process the result from the retry helper.
        switch result {
        case .success(let response):
            // Check for Lambda function errors (distinct from invocation errors).
            if let functionError = response.functionError {
                logger.error("[\(operationType)] Lambda function '\(functionName)' returned an error: \(functionError). ID: \(invocationId)")
                // Depending on the API contract, some function errors might be retryable by the *caller* (e.g. retrying the whole process).
                // However, the `executeWithRetry` already handled transient *invocation* errors.
                // Function errors often indicate a problem with the input or the Lambda code itself, usually not retryable at this level.
                return nil
            }

            // If async invocation (.event), there's no response payload to parse for T.
            if invocationType == .event {
                logger.info("[\(operationType)] Successfully submitted async invocation for Lambda function '\(functionName)'. ID: \(invocationId)")
                // For async invocations, the success is just confirming the request was accepted.
                // If the caller expects a Bool indicating submission success, handle that case.
                 if T.self == Bool.self {
                      return true as? T // Indicate async submission success
                 }
                return nil // Cannot return a Decodable T for async invocation
            }

            // Process synchronous response payload for .requestResponse.
            guard let responsePayload = response.payload else {
                logger.error("[\(operationType)] Lambda function '\(functionName)' returned empty response payload for synchronous invocation. ID: \(invocationId)")
                return nil
            }

            // Deserialize the response payload.
            do {
                let decoder = JSONDecoder()
                 // Add date decoding strategy if needed, e.g.:
                 // decoder.dateDecodingStrategy = .iso8601
                let decodedResult = try decoder.decode(T.self, from: responsePayload)
                logger.info("[\(operationType)] Successfully invoked Lambda function '\(functionName)' and parsed response. ID: \(invocationId)")
                return decodedResult
            } catch {
                // Log the payload for debugging parsing errors
                logger.error("[\(operationType)] Failed to parse Lambda response payload for function '\(functionName)': \(error.localizedDescription). Payload: \(String(data: responsePayload, encoding: .utf8) ?? "Invalid UTF-8"). ID: \(invocationId)")
                return nil
            }

        case .failure(let error):
            // Error already logged by executeWithRetry.
             logger.error("[\(operationType)] Lambda invocation failed for function '\(functionName)' after all retries. ID: \(invocationId)")
            return nil
        }
    }

    /// Executes a given async Lambda operation with retry logic.
     private func executeWithRetry<T>(
         maxAttempts: Int,
         operationType: String,
         key: String? = nil,
         operation: @escaping () async throws -> T
     ) async -> Result<T, Error> {
         for attempt in 0..<maxAttempts {
             let startTime = Date()
             do {
                 logger.debug("[\(operationType)] Attempt \(attempt + 1)/\(maxAttempts)... Key: \(key ?? "N/A")")
                 let result = try await operation()
                 let duration = Date().timeIntervalSince(startTime)
                 logger.trace("[\(operationType)] Attempt \(attempt + 1) succeeded in \(duration)s. Key: \(key ?? "N/A")")
                 return .success(result)
             } catch let error as NSError {
                 let duration = Date().timeIntervalSince(startTime)
                 logger.warning("[\(operationType)] Attempt \(attempt + 1)/\(maxAttempts) failed in \(duration)s: \(error.localizedDescription), Code: \(error.code), Domain: \(error.domain). Key: \(key ?? "N/A")")

                 guard isRetryableLambdaError(error), attempt < maxAttempts - 1 else {
                     logger.error("[\(operationType)] Operation failed after \(attempt + 1) attempts. Will not retry. Key: \(key ?? "N/A")")
                     return .failure(error)
                 }

                 let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                 logger.info("[\(operationType)] Retrying after \(String(format: "%.2f", delay)) seconds... Key: \(key ?? "N/A")")
                 try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
             } catch {
                 let duration = Date().timeIntervalSince(startTime)
                 logger.error("[\(operationType)] An unexpected error occurred during attempt \(attempt + 1)/\(maxAttempts) after \(duration)s: \(error). Key: \(key ?? "N/A")")
                 if attempt >= maxAttempts - 1 {
                     return .failure(error)
                 }
                 let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                 try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
             }
         }
         return .failure(NSError(domain: "LambdaServiceError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Exhausted retries unexpectedly"]))
     }

    /// Creates a JSON payload for image processing Lambda requests.
    private func createImageProcessingPayload(imageData: Data, metadata: [String: Any]) -> [String: Any]? {
        let hash = SHA256.hash(data: imageData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        let base64EncodedImage = imageData.base64EncodedString()

        var payload: [String: Any] = [
            "requestType": "imageProcessing", // Identifier for Lambda routing
            "image": [
                "data": base64EncodedImage,
                "hash": hashString,
                "size": imageData.count
            ],
            "metadata": metadata // Pass through application metadata
        ]
        return payload
    }

    /// Creates a JSON payload for S3-based processing Lambda requests.
    private func createS3ProcessingPayload(bucket: String, key: String, metadata: [String: Any]) -> [String: Any]? {
        var payload: [String: Any] = [
            "requestType": "s3Processing", // Identifier for Lambda routing
            "s3": [
                "bucket": bucket,
                "key": key
            ],
            "metadata": metadata
        ]
        return payload
    }

    /// Creates a JSON payload for hash validation Lambda requests.
    private func createHashValidationPayload(hash: String) -> [String: Any]? {
        let payload: [String: Any] = [
            "requestType": "hashValidation", // Identifier for Lambda routing
            "hash": hash
        ]
        return payload
    }

    /// Checks if an `NSError` from Lambda or related network issues is retryable.
    private func isRetryableLambdaError(_ error: NSError) -> Bool {
        // Lambda-specific retryable errors
        if error.domain == AWSLambdaErrorDomain {
            switch AWSLambdaErrorType(rawValue: error.code) {
            // ServiceException, TooManyRequestsException, EC2ThrottledException etc. are potentially retryable
            case .serviceException, .tooManyRequestsException, .ec2ThrottledException,
                 .ec2UnexpectedException, .kmsDisabledException, .kmsInvalidStateException,
                 .kmsAccessDeniedException, .kmsNotFoundException, .efsioException,
                 .efsMountConnectivityException, .efsMountFailureException, .efsMountTimeoutException,
                 .eniRequestLimitExceededException, .subnetIPAddressLimitReachedException,
                 .resourceNotReadyException: // ResourceNotReady might be temporary
                return true
            default:
                break // Check other domains
            }
        }

        // General AWS service errors that might be retryable
        if error.domain == AWSServiceErrorDomain {
            switch AWSServiceErrorType(rawValue: error.code) {
            case .throttling, .requestTimeout, .serviceUnavailable, .internalFailure:
                return true
            default:
                break
            }
        }

        // Standard network connection errors
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return true
            default:
                break
            }
        }

        // Default to non-retryable
        return false
    }

     // MARK: - Invocation Tracking Helpers

     /// Adds an invocation ID to the set of ongoing operations.
     private func trackInvocationStart(id: UUID) {
         trackingLock.lock()
         ongoingInvocations.insert(id)
         trackingLock.unlock()
         logger.trace("Started tracking Lambda invocation: \(id)")
     }

     /// Removes an invocation ID from the set of ongoing operations.
     private func trackInvocationEnd(id: UUID) {
         trackingLock.lock()
         ongoingInvocations.remove(id)
         trackingLock.unlock()
         logger.trace("Finished tracking Lambda invocation: \(id)")
     }

     /// Returns the number of currently tracked ongoing Lambda invocations.
     public func numberOfOngoingInvocations() -> Int {
         trackingLock.lock()
         defer { trackingLock.unlock() }
         return ongoingInvocations.count
     }
}

// MARK: - Response Types

/// Represents the result of a content processing operation performed by Lambda.
/// Matches the structure defined in `aws-config.json` comments or Lambda function output.
public struct ContentProcessingResult: Codable {
    /// Indicates whether the overall processing was successful from Lambda's perspective.
    public let success: Bool
    /// A string describing the outcome (e.g., "completed", "blocked", "failed").
    public let status: String
    /// The computed content hash (e.g., SHA-256), if generated.
    public let contentHash: String?
    /// A list of identifiers for any issues detected (e.g., "policy_violation", "format_unsupported").
    public let detectedIssues: [String]?
    /// A score (0-100) indicating confidence in the detection results.
    public let confidenceScore: Double?
    /// Additional key-value data returned by the processor (e.g., format, dimensions).
    public let resultData: [String: String]?
    /// An error message if `success` is false.
    public let errorMessage: String?
}

/// Type alias for content hash validation results, assuming it uses the same structure.
public typealias ContentValidationResult = ContentProcessingResult

/// Represents the response from triggering an S3 to DynamoDB transfer (if invoked synchronously).
public struct S3TransferResponse: Codable {
    /// A unique identifier for the batch transfer job, if provided by the Lambda.
    public let jobId: String?
    /// A message indicating the status of the trigger request.
    public let message: String?
}

// MARK: - AWSTask Extension (if needed)

// Include the AWSTask extension here or ensure it's accessible if defined elsewhere.
extension AWSTask {
    /// Converts an AWSTask to a Swift Concurrency async/await operation.
    func aws_await<Result>() async throws -> Result {
         return try await withCheckedThrowingContinuation { continuation in
             self.continueWith { task -> Void in
                 if let error = task.error {
                     continuation.resume(throwing: error)
                 } else if let exception = task.exception {
                     continuation.resume(throwing: NSError(
                         domain: "AWSTaskException",
                         code: 0,
                         userInfo: [NSLocalizedDescriptionKey: "Task threw exception: \(exception)"]
                     ))
                 } else if task.isCancelled {
                      continuation.resume(throwing: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                 } else if let result = task.result as? Result {
                     continuation.resume(returning: result)
                 } else if Result.self == Void.self {
                      continuation.resume(returning: () as! Result)
                 } else {
                     continuation.resume(throwing: NSError(
                         domain: "AWSTaskError",
                         code: 0,
                         userInfo: [NSLocalizedDescriptionKey: "Task completed with incompatible result type \(type(of: task.result)) when expecting \(Result.self) or Void."]
                     ))
                 }
             }
         }
     }
 }
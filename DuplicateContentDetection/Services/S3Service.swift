//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSS3
import Logging
import CryptoKit
import UniformTypeIdentifiers

// Assuming S3toDynamoDBImporter.ImportFormat enum is accessible, e.g., if this file
// is part of the same module as S3toDynamoDBImporter.swift.

/// Service for interacting with AWS S3 for file storage and retrieval.
/// Handles uploads, downloads, existence checks, pre-signed URLs, and deletions,
/// including retry logic and error handling.
public final class S3Service {
    // MARK: - Singleton

    /// Shared instance for accessing the service throughout the app.
    public static let shared = S3Service()

    // MARK: - Constants

    /// The name of the S3 bucket used for attachments and other content.
    /// This should match the bucket name configured in AWS. Fetched from aws-config.json conceptually.
    public let attachmentBucketName = "signal-content-attachments"

    /// The AWS region where the S3 service is located. Should match AWSConfig region.
    /// Fetched from aws-config.json conceptually via AWSConfig.swift.
    public let s3Region = AWSConfig.cognitoRegion

    /// Default expiration time for pre-signed URLs (in seconds).
    public let defaultURLExpirationSeconds: TimeInterval = 3600 // 1 hour

    /// Default number of times to retry failed S3 operations.
    public let defaultRetryCount = AWSConfig.maxRetryCount

    // MARK: - Private Properties

    /// S3 client for interacting with AWS, configured via AWSConfig.
    private let client: AWSS3

    /// Logger for capturing service operations and errors.
    private let logger = Logger(label: "org.signal.S3Service")

    /// Helper for detecting MIME types based on file data.
    private let mimeTypeDetector = MIMETypeDetector()

    // MARK: - Initialization

    /// Private initializer for singleton pattern. Configures the S3 client.
    private init() {
        // Ensure AWS credentials are set up via AWSConfig.
        if AWSServiceManager.default().defaultServiceConfiguration == nil {
            AWSConfig.setupAWSCredentials()
        }

        // Configure S3 client with custom timeouts and retry settings from AWSConfig.
        let s3Configuration = AWSS3ServiceConfiguration(
            region: s3Region,
            credentialsProvider: AWSServiceManager.default().defaultServiceConfiguration?.credentialsProvider
        )
        s3Configuration.timeoutIntervalForRequest = AWSConfig.requestTimeoutInterval
        s3Configuration.timeoutIntervalForResource = AWSConfig.resourceTimeoutInterval
        s3Configuration.maxRetryCount = UInt32(AWSConfig.maxRetryCount)

        // Register the S3 client with a specific key.
        AWSS3.register(with: s3Configuration, forKey: "CustomS3Client")

        // Retrieve the registered client.
        if let specificClient = AWSS3(forKey: "CustomS3Client") {
            self.client = specificClient
        } else {
            // Fallback to default if registration fails (should not happen ideally).
            self.client = AWSS3.default()
            logger.warning("Using default S3 client configuration as custom registration failed.")
        }

        logger.info("Initialized S3Service for region \(s3Region.stringValue) and bucket: \(attachmentBucketName)")
    }

    // MARK: - Helper: Execute with Retry

    /// Executes a given async S3 operation with retry logic.
    private func executeWithRetry<T>(
        maxAttempts: Int,
        operationType: String,
        key: String?, // Optional key for logging context
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

                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
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
        // Should not be reached if maxAttempts > 0
        return .failure(NSError(domain: "S3ServiceError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Exhausted retries unexpectedly"]))
    }

    // MARK: - Public API: File Upload

    /// Uploads file data to a specified S3 key within a bucket.
    /// - Parameters:
    ///   - data: The `Data` to upload.
    ///   - key: The destination object key (path) in S3.
    ///   - bucket: The name of the S3 bucket. Defaults to `attachmentBucketName`.
    ///   - contentType: Optional MIME type. If nil, it will be auto-detected.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    /// - Returns: `true` if the upload was successful, `false` otherwise.
    public func uploadFile(
        data: Data,
        key: String,
        bucket: String? = nil,
        contentType: String? = nil,
        retryCount: Int? = nil
    ) async -> Bool {
        let targetBucket = bucket ?? attachmentBucketName
        let maxAttempts = retryCount ?? defaultRetryCount
        let operationType = "UploadFile"

        // Determine content type if not provided.
        let mimeType = contentType ?? mimeTypeDetector.detectMIMEType(for: data)

        // Create the S3 PutObject request.
        guard let uploadRequest = AWSS3PutObjectRequest() else {
            logger.error("[\(operationType)] Failed to create PutObjectRequest for key: \(key)")
            return false
        }
        uploadRequest.bucket = targetBucket
        uploadRequest.key = key
        uploadRequest.body = data
        uploadRequest.contentType = mimeType
        uploadRequest.contentLength = NSNumber(value: data.count)
        uploadRequest.serverSideEncryption = .aes256 // Enable server-side encryption (SSE-S3)
        uploadRequest.acl = .private // Ensure objects are private by default

        logger.info("[\(operationType)] Uploading file to S3: Bucket=\(targetBucket), Key=\(key), Size=\(data.count) bytes, Type=\(mimeType)")

        // Execute the operation with retry logic.
        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: key) {
             _ = try await self.client.putObject(uploadRequest).aws_await() // Use aws_await extension
        }

        switch result {
        case .success:
            logger.info("[\(operationType)] Successfully uploaded file to S3: \(key)")
            return true
        case .failure:
            // Error already logged by executeWithRetry
            return false
        }
    }

    // MARK: - Public API: File Download

    /// Downloads a file from S3 for a given key and bucket.
    /// - Parameters:
    ///   - key: The object key (path) in S3.
    ///   - bucket: The name of the S3 bucket. Defaults to `attachmentBucketName`.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    /// - Returns: The downloaded `Data` or `nil` if the download fails or the file doesn't exist.
    public func downloadFile(
        key: String,
        bucket: String? = nil,
        retryCount: Int? = nil
    ) async -> Data? {
        let targetBucket = bucket ?? attachmentBucketName
        let maxAttempts = retryCount ?? defaultRetryCount
        let operationType = "DownloadFile"

        // Create the S3 GetObject request.
        guard let downloadRequest = AWSS3GetObjectRequest() else {
            logger.error("[\(operationType)] Failed to create GetObjectRequest for key: \(key)")
            return nil
        }
        downloadRequest.bucket = targetBucket
        downloadRequest.key = key

        logger.info("[\(operationType)] Downloading file from S3: Bucket=\(targetBucket), Key=\(key)")

        // Execute the operation with retry logic.
        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: key) {
             try await self.client.getObject(downloadRequest).aws_await()
        }

        switch result {
        case .success(let output):
            // Extract the data from the response body.
            guard let body = output.body as? Data else {
                logger.error("[\(operationType)] Invalid response body (not Data) for key: \(key)")
                return nil
            }
            logger.info("[\(operationType)] Successfully downloaded file from S3: \(key) (\(body.count) bytes)")
            return body
        case .failure(let error as NSError):
            // Handle NoSuchKey specifically - file doesn't exist, not necessarily a failure to retry.
            if error.domain == AWSS3ErrorDomain, error.code == AWSS3ErrorType.noSuchKey.rawValue {
                logger.warning("[\(operationType)] File does not exist in S3: \(key)")
                return nil // File not found is not an operational failure here.
            }
            // Other errors logged by executeWithRetry
            return nil
        case .failure:
             // Other unexpected errors logged by executeWithRetry
             return nil
        }
    }

    // MARK: - Public API: File Existence Check

    /// Checks if a file exists in S3 using a HEAD request.
    /// - Parameters:
    ///   - key: The object key (path) in S3.
    ///   - bucket: The name of the S3 bucket. Defaults to `attachmentBucketName`.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    ///   - Returns: `true` if the file exists, `false` otherwise (including errors).
    public func fileExists(
        key: String,
        bucket: String? = nil,
        retryCount: Int? = nil
    ) async -> Bool {
        let targetBucket = bucket ?? attachmentBucketName
        let maxAttempts = retryCount ?? defaultRetryCount
        let operationType = "FileExistsCheck"

        // Create the S3 HeadObject request.
        guard let headRequest = AWSS3HeadObjectRequest() else {
            logger.error("[\(operationType)] Failed to create HeadObjectRequest for key: \(key)")
            return false
        }
        headRequest.bucket = targetBucket
        headRequest.key = key

        logger.debug("[\(operationType)] Checking existence in S3: Bucket=\(targetBucket), Key=\(key)")

        // Execute the operation with retry logic.
        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: key) {
            _ = try await self.client.headObject(headRequest).aws_await()
        }

        switch result {
        case .success:
            logger.debug("[\(operationType)] File exists in S3: \(key)")
            return true
        case .failure(let error as NSError):
            // If the error is 404 Not Found (NoSuchKey), the file does not exist.
            if error.domain == AWSS3ErrorDomain, error.code == AWSS3ErrorType.noSuchKey.rawValue {
                 logger.debug("[\(operationType)] File does not exist in S3: \(key)")
                 return false // File not found is the expected outcome here.
             }
             // Other errors indicate a problem checking, default to false.
             logger.warning("[\(operationType)] Error checking file existence for key \(key): \(error.localizedDescription)")
             return false
        case .failure:
              // Unexpected non-NSError, default to false.
              logger.warning("[\(operationType)] Unexpected error checking file existence for key \(key)")
              return false
        }
    }

    // MARK: - Public API: Pre-signed URLs

    /// Generates a pre-signed URL for temporarily accessing an S3 object (usually for download).
    /// - Parameters:
    ///   - key: The object key (path) in S3.
    ///   - bucket: The name of the S3 bucket. Defaults to `attachmentBucketName`.
    ///   - expiresIn: Expiration time in seconds. Defaults to `defaultURLExpirationSeconds`.
    ///   - httpMethod: The HTTP method the URL is valid for (GET, PUT, etc.). Defaults to GET.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    /// - Returns: A pre-signed `URL` or `nil` if generation fails.
    public func generatePresignedURL(
        for key: String,
        bucket: String? = nil,
        expiresIn: TimeInterval? = nil,
        httpMethod: AWSHTTPMethod = .GET,
        retryCount: Int? = nil
    ) async -> URL? {
        let targetBucket = bucket ?? attachmentBucketName
        let expirationTime = expiresIn ?? defaultURLExpirationSeconds
        let maxAttempts = retryCount ?? defaultRetryCount
        let operationType = "GeneratePresignedURL"

        // Create the S3 GetPreSignedURLRequest.
        guard let urlRequest = AWSS3GetPreSignedURLRequest() else {
            logger.error("[\(operationType)] Failed to create GetPreSignedURLRequest for key: \(key)")
            return nil
        }
        urlRequest.bucket = targetBucket
        urlRequest.key = key
        urlRequest.httpMethod = httpMethod
        urlRequest.expires = Date(timeIntervalSinceNow: expirationTime)

        logger.debug("[\(operationType)] Generating pre-signed URL: Bucket=\(targetBucket), Key=\(key), Method=\(httpMethod.stringValue), Expires=\(expirationTime)s")

        // Execute the operation with retry logic.
        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: key) {
            try await AWSS3PreSignedURLBuilder.default().getPreSignedURL(urlRequest).aws_await()
        }

        switch result {
        case .success(let presignedURL):
            logger.info("[\(operationType)] Successfully generated pre-signed URL for: \(key)")
            return presignedURL
        case .failure:
            // Error logged by executeWithRetry
            return nil
        }
    }

    // MARK: - Public API: File Deletion

    /// Deletes an object from S3 specified by key and bucket.
    /// - Parameters:
    ///   - key: The object key (path) in S3.
    ///   - bucket: The name of the S3 bucket. Defaults to `attachmentBucketName`.
    ///   - retryCount: Optional number of retry attempts. Defaults to `defaultRetryCount`.
    /// - Returns: `true` if deletion was successful (or if the object didn't exist), `false` otherwise.
    public func deleteFile(
        key: String,
        bucket: String? = nil,
        retryCount: Int? = nil
    ) async -> Bool {
        let targetBucket = bucket ?? attachmentBucketName
        let maxAttempts = retryCount ?? defaultRetryCount
        let operationType = "DeleteFile"

        // Create the S3 DeleteObject request.
        guard let deleteRequest = AWSS3DeleteObjectRequest() else {
            logger.error("[\(operationType)] Failed to create DeleteObjectRequest for key: \(key)")
            return false
        }
        deleteRequest.bucket = targetBucket
        deleteRequest.key = key

        logger.info("[\(operationType)] Deleting file from S3: Bucket=\(targetBucket), Key=\(key)")

        // Execute the operation with retry logic.
        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: key) {
            _ = try await self.client.deleteObject(deleteRequest).aws_await()
        }

        switch result {
        case .success:
            logger.info("[\(operationType)] Successfully deleted file from S3: \(key)")
            return true
        case .failure(let error as NSError):
             // Deleting a non-existent key might return NoSuchKey, but S3 generally treats delete as idempotent.
             // Check AWS documentation if specific handling for 404 on DELETE is needed.
             // Often, no error is returned even if key doesn't exist.
             // If an error occurs, log it but return based on retry failure.
             // Error logged by executeWithRetry
             return false
         case .failure:
              // Error logged by executeWithRetry
              return false
        }
    }

    // MARK: - Specialized Methods for Hash Data

    /// Uploads formatted hash data (e.g., CSV, JSON) to S3.
    /// This is essentially a wrapper around `uploadFile` with specific parameters.
    /// - Parameters:
    ///   - data: The pre-formatted `Data` containing hashes (e.g., CSV or JSON).
    ///   - format: The format of the data, used to determine content type and potentially path.
    ///   - bucket: The target S3 bucket. Defaults to `attachmentBucketName`.
    ///   - prefix: Optional S3 prefix (folder path) for the upload. Defaults to "hash-imports/".
    ///   - retryCount: Optional number of retry attempts.
    /// - Returns: The S3 key used for the upload, or `nil` on failure.
    public func uploadHashData(
        data: Data,
        format: S3toDynamoDBImporter.ImportFormat, // Assuming format enum is accessible
        bucket: String? = nil,
        prefix: String? = "hash-imports/", // Default prefix for hash files
        retryCount: Int? = nil
    ) async -> String? {
        let operationType = "UploadHashData"
        let fileExtension: String
        let contentType: String

        switch format {
        case .csv:
            fileExtension = "csv"
            contentType = "text/csv"
        case .json:
            fileExtension = "json"
            contentType = "application/json"
        }

        // Generate a unique key including the prefix and extension.
        let key = generateUniqueKey(prefix: prefix, fileExtension: fileExtension)
        let targetBucket = bucket ?? attachmentBucketName

        logger.info("[\(operationType)] Preparing to upload \(format) hash data to S3: Key=\(key)")

        // Use the standard uploadFile method.
        let success = await uploadFile(
            data: data,
            key: key,
            bucket: targetBucket,
            contentType: contentType,
            retryCount: retryCount
        )

        if success {
            logger.info("[\(operationType)] Successfully uploaded hash data: \(key)")
            return key
        } else {
            logger.error("[\(operationType)] Failed to upload hash data: \(key)")
            return nil
        }
    }


    // MARK: - Helper Methods

    /// Checks if an NSError from AWS S3 or network operations is retryable.
    private func isRetryableAWSError(_ error: NSError) -> Bool {
        // Standard AWS service errors considered retryable
        if error.domain == AWSServiceErrorDomain {
            switch AWSServiceErrorType(rawValue: error.code) {
            case .throttling, .requestTimeout, .serviceUnavailable, .internalFailure:
                return true
            default:
                break
            }
        }

        // S3-specific errors considered retryable
        if error.domain == AWSS3ErrorDomain {
            switch AWSS3ErrorType(rawValue: error.code) {
            // Service unavailable, slowdown, internal errors, timeouts are good candidates
            case .serviceUnavailable, .slowDown, .internalError, .requestTimeout:
                return true
            // NoSuchKey is not retryable in the context of checking existence or getting data
            // AccessDenied is generally not retryable
            // InvalidArgument, etc. are not retryable
            default:
                break
            }
        }

        // Network connection errors are generally retryable
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

    /// Generates a unique key for storing a file, incorporating a prefix and extension.
    public func generateUniqueKey(prefix: String? = nil, fileExtension: String? = nil) -> String {
        let uuid = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)

        var key = "\(uuid)-\(timestamp)"

        if let ext = fileExtension?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !ext.isEmpty {
            let sanitizedExt = ext.replacingOccurrences(of: ".", with: "") // Remove existing dots
            key += ".\(sanitizedExt)"
        }

        if let pfx = prefix?.trimmingCharacters(in: .whitespacesAndNewlines), !pfx.isEmpty {
            let folderPrefix = pfx.hasSuffix("/") ? pfx : "\(pfx)/"
            key = folderPrefix + key
        }

        return key
    }
}

// MARK: - MIME Type Detection Helper

/// Helper class for basic MIME type detection based on file signatures or heuristics.
fileprivate class MIMETypeDetector {
    private let defaultMIMEType = "application/octet-stream"

    // Common file signatures
    private let signatures: [(signature: [UInt8], mimeType: String)] = [
        (signature: [0xFF, 0xD8, 0xFF], mimeType: "image/jpeg"),
        (signature: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], mimeType: "image/png"),
        (signature: [0x47, 0x49, 0x46, 0x38], mimeType: "image/gif"),
        (signature: [0x25, 0x50, 0x44, 0x46], mimeType: "application/pdf"),
        (signature: [0x50, 0x4B, 0x03, 0x04], mimeType: "application/zip"),
        (signature: [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70], mimeType: "video/mp4"), // Example for MP4
        (signature: [0x7B, 0x22], mimeType: "application/json"), // Starts with '{' for JSON
        (signature: [0x5B, 0x7B], mimeType: "application/json"), // Starts with '[' for JSON array
    ]

    /// Detects the MIME type of the given data.
    func detectMIMEType(for data: Data) -> String {
        if let mimeType = detectFromSignature(data) {
            return mimeType
        }

        // Use UTType for more robust detection if available
        if #available(iOS 14.0, *) {
             // Create a temporary file to leverage UTType's file-based detection
             let tempDir = FileManager.default.temporaryDirectory
             let tempURL = tempDir.appendingPathComponent(UUID().uuidString)
             defer { try? FileManager.default.removeItem(at: tempURL) }

             do {
                 try data.write(to: tempURL)
                 if let type = UTType(contentsOf: tempURL), let mimeType = type.preferredMIMEType {
                     return mimeType
                 }
             } catch {
                 // Fall through if temp file creation fails
             }
        }

        // Basic heuristic for text files
        if isLikelyText(data) {
            return "text/plain"
        }

        return defaultMIMEType
    }

    /// Detects MIME type from known file signatures (magic numbers).
    private func detectFromSignature(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(16)) // Check first 16 bytes

        for (signature, mimeType) in signatures {
            guard signature.count <= bytes.count else { continue }
            if bytes.starts(with: signature) {
                return mimeType
            }
        }
        return nil
    }

    /// Simple heuristic to guess if data is likely text-based (UTF-8 or ASCII).
    private func isLikelyText(_ data: Data) -> Bool {
        let sampleSize = min(512, data.count)
        guard sampleSize > 0 else { return false }
        let sample = data.prefix(sampleSize)

        // Check for null bytes, common in binary files
        if sample.contains(0) {
            return false
        }

        // Attempt to decode as UTF-8
        if String(data: sample, encoding: .utf8) != nil {
            // Check proportion of printable ASCII characters
            var printableCount = 0
            for byte in sample {
                if (byte >= 32 && byte <= 126) || byte == 9 || byte == 10 || byte == 13 {
                    printableCount += 1
                }
            }
            // If a high percentage are printable ASCII, assume text
            return Double(printableCount) / Double(sampleSize) > 0.9
        }

        return false
    }
}

// MARK: - AWSTask Extension for Async/Await

// Helper extension to bridge AWSTask with Swift Concurrency
// Should ideally live in a shared utility file accessible by all modules using AWSTask.
// If it's already defined in SignalServiceKit or another shared module, remove this.
extension AWSTask {
    /// Converts an AWSTask to a Swift Concurrency async/await operation.
    /// - Returns: The result of the task.
    /// - Throws: Any error the task encountered.
    func aws_await<Result>() async throws -> Result {
        return try await withCheckedThrowingContinuation { continuation in
            self.continueWith { task -> Void in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else if let exception = task.exception {
                    // Convert NSException to NSError
                    continuation.resume(throwing: NSError(
                        domain: "AWSTaskException",
                        code: 0, // Use a specific code or map exception type
                        userInfo: [NSLocalizedDescriptionKey: "Task threw exception: \(exception)"]
                    ))
                } else if task.isCancelled {
                     continuation.resume(throwing: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                } else if let result = task.result as? Result {
                    continuation.resume(returning: result)
                } else if Result.self == Void.self {
                     // Handle Void result case, common for operations like putObject, deleteObject, headObject
                     continuation.resume(returning: () as! Result)
                } else {
                    // If result type doesn't match and isn't Void
                    continuation.resume(throwing: NSError(
                        domain: "AWSTaskError",
                        code: 0, // Use a specific code
                        userInfo: [NSLocalizedDescriptionKey: "Task completed with incompatible result type \(type(of: task.result)) when expecting \(Result.self) or Void."]
                    ))
                }
            }
        }
    }
}

// Add placeholder for S3toDynamoDBImporter.ImportFormat if needed for compilation
// If S3toDynamoDBImporter is in the same module, this isn't necessary.
#if !BUILDING_DUPLICATECONTENTDETECTION // Or appropriate compile flag
public class S3toDynamoDBImporter {
     public enum ImportFormat { case csv, json }
}
#endif

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

/// Service for interacting with AWS S3 for file storage and retrieval
public final class S3Service {
    // MARK: - Singleton
    
    /// Shared instance for accessing the service throughout the app
    public static let shared = S3Service()
    
    // MARK: - Constants
    
    /// The name of the S3 bucket for attachments
    public let attachmentBucketName = "signal-content-attachments"
    
    /// The AWS region for the S3 service
    public let s3Region = AWSRegionType.USWest2
    
    /// Default expiration time for pre-signed URLs (in seconds)
    public let defaultURLExpirationSeconds: TimeInterval = 3600 // 1 hour
    
    /// Default time for retrying failed operations
    public let defaultRetryCount = 3
    
    // MARK: - Private Properties
    
    /// S3 client for interacting with AWS
    private let client: AWSS3
    
    /// Logger for capturing service operations
    private let logger = Logger(label: "org.signal.S3Service")
    
    /// MIME type detector for content validation
    private let mimeTypeDetector = MIMETypeDetector()
    
    // MARK: - Initialization
    
    /// Private initializer for singleton
    private init() {
        // Get the configured S3 client using AWSConfig's credentials
        if AWSServiceManager.default().defaultServiceConfiguration == nil {
            AWSConfig.setupAWSCredentials()
        }
        
        // Configure AWSS3 with custom settings
        let s3Configuration = AWSS3ServiceConfiguration()
        s3Configuration.timeoutIntervalForRequest = AWSConfig.requestTimeoutInterval
        s3Configuration.timeoutIntervalForResource = AWSConfig.resourceTimeoutInterval
        s3Configuration.maxRetryCount = AWSConfig.maxRetryCount
        
        // Register S3 with the custom configuration
        AWSS3.register(
            with: AWSServiceManager.default().defaultServiceConfiguration!,
            forKey: "DefaultS3",
            serviceConfiguration: s3Configuration
        )
        
        // Get the client instance
        if let client = AWSS3.s3(forKey: "DefaultS3") {
            self.client = client
        } else {
            self.client = AWSS3.default()
            logger.warning("Using default S3 client configuration")
        }
        
        logger.info("Initialized S3Service with bucket: \(attachmentBucketName)")
    }
    
    // MARK: - Public API: File Upload
    
    /// Uploads a file to S3
    /// - Parameters:
    ///   - data: The file data to upload
    ///   - key: The object key/path in S3
    ///   - contentType: Optional MIME type for the file, auto-detected if nil
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: Boolean indicating success
    public func uploadFile(data: Data, key: String, contentType: String? = nil, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        
        // Determine content type if not provided
        let mimeType = contentType ?? mimeTypeDetector.detectMIMEType(for: data)
        
        // Create upload request
        guard let uploadRequest = AWSS3PutObjectRequest() else {
            logger.error("[Upload] Failed to create PutObjectRequest for key: \(key)")
            return false
        }
        
        uploadRequest.bucket = attachmentBucketName
        uploadRequest.key = key
        uploadRequest.body = data
        uploadRequest.contentType = mimeType
        uploadRequest.contentLength = NSNumber(value: data.count)
        
        // Set server-side encryption
        uploadRequest.serverSideEncryption = .aes256
        
        // Set ACL to private for security
        uploadRequest.acl = .private
        
        logger.info("[Upload] Uploading file to S3: bucket=\(attachmentBucketName), key=\(key), size=\(data.count) bytes, type=\(mimeType)")
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[Upload] Attempt \(attempt + 1)/\(maxAttempts) to upload file: \(key)")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                _ = try await withCheckedThrowingContinuation { continuation in
                    client.putObject(uploadRequest).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                logger.info("[Upload] Successfully uploaded file to S3: \(key)")
                return true
                
            } catch let error as NSError {
                logger.warning("[Upload] S3 putObject failed for key \(key) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[Upload] S3 putObject failed after \(attempt + 1) attempts for key \(key). Will not retry.")
                    return false
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                logger.info("[Upload] Retrying S3 putObject for key \(key) after \(String(format: "%.2f", delay)) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[Upload] An unexpected error occurred during S3 putObject for key \(key): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return false
                }
                
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[Upload] Reached end of uploadFile function unexpectedly for key \(key).")
        return false
    }
    
    // MARK: - Public API: File Download
    
    /// Downloads a file from S3
    /// - Parameters:
    ///   - key: The object key/path in S3
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: The downloaded data or nil if the download fails
    public func downloadFile(key: String, retryCount: Int? = nil) async -> Data? {
        let maxAttempts = retryCount ?? defaultRetryCount
        
        // Create download request
        guard let downloadRequest = AWSS3GetObjectRequest() else {
            logger.error("[Download] Failed to create GetObjectRequest for key: \(key)")
            return nil
        }
        
        downloadRequest.bucket = attachmentBucketName
        downloadRequest.key = key
        
        logger.info("[Download] Downloading file from S3: bucket=\(attachmentBucketName), key=\(key)")
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[Download] Attempt \(attempt + 1)/\(maxAttempts) to download file: \(key)")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                let output = try await withCheckedThrowingContinuation { continuation in
                    client.getObject(downloadRequest).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                // Extract the data from the response
                guard let body = output.body as? Data else {
                    logger.error("[Download] Invalid response body (not Data) for key: \(key)")
                    return nil
                }
                
                logger.info("[Download] Successfully downloaded file from S3: \(key) (\(body.count) bytes)")
                return body
                
            } catch let error as NSError {
                // Check if the file doesn't exist
                if error.domain == AWSS3ErrorDomain, error.code == AWSS3ErrorType.noSuchKey.rawValue {
                    logger.warning("[Download] File does not exist in S3: \(key)")
                    return nil // No need to retry, file simply doesn't exist
                }
                
                logger.warning("[Download] S3 getObject failed for key \(key) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[Download] S3 getObject failed after \(attempt + 1) attempts for key \(key). Will not retry.")
                    return nil
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                logger.info("[Download] Retrying S3 getObject for key \(key) after \(String(format: "%.2f", delay)) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[Download] An unexpected error occurred during S3 getObject for key \(key): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return nil
                }
                
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[Download] Reached end of downloadFile function unexpectedly for key \(key).")
        return nil
    }
    
    // MARK: - Public API: File Existence Check
    
    /// Checks if a file exists in S3
    /// - Parameters:
    ///   - key: The object key/path in S3
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: Boolean indicating if the file exists
    public func fileExists(key: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        
        // Create head request (more efficient than downloading)
        guard let headRequest = AWSS3HeadObjectRequest() else {
            logger.error("[Exists] Failed to create HeadObjectRequest for key: \(key)")
            return false
        }
        
        headRequest.bucket = attachmentBucketName
        headRequest.key = key
        
        logger.debug("[Exists] Checking if file exists in S3: bucket=\(attachmentBucketName), key=\(key)")
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[Exists] Attempt \(attempt + 1)/\(maxAttempts) to check file existence: \(key)")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                _ = try await withCheckedThrowingContinuation { continuation in
                    client.headObject(headRequest).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                logger.debug("[Exists] File exists in S3: \(key)")
                return true
                
            } catch let error as NSError {
                // Check if the file doesn't exist (expected error case)
                if error.domain == AWSS3ErrorDomain, error.code == AWSS3ErrorType.noSuchKey.rawValue {
                    logger.debug("[Exists] File does not exist in S3: \(key)")
                    return false
                }
                
                logger.warning("[Exists] S3 headObject failed for key \(key) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[Exists] S3 headObject failed after \(attempt + 1) attempts for key \(key). Will not retry.")
                    return false // Default to not exists on error
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[Exists] An unexpected error occurred during S3 headObject for key \(key): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return false // Default to not exists on error
                }
                
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[Exists] Reached end of fileExists function unexpectedly for key \(key).")
        return false
    }
    
    // MARK: - Public API: Pre-signed URLs
    
    /// Generates a pre-signed URL for downloading a file
    /// - Parameters:
    ///   - key: The object key/path in S3
    ///   - expiresIn: Expiration time in seconds (defaults to 1 hour)
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: A pre-signed URL or nil if generation fails
    public func generatePresignedURL(for key: String, expiresIn: TimeInterval? = nil, retryCount: Int? = nil) async -> URL? {
        let maxAttempts = retryCount ?? defaultRetryCount
        let expirationTime = expiresIn ?? defaultURLExpirationSeconds
        
        // Create pre-signed URL request
        guard let urlRequest = AWSS3GetPreSignedURLRequest() else {
            logger.error("[URL] Failed to create GetPreSignedURLRequest for key: \(key)")
            return nil
        }
        
        urlRequest.bucket = attachmentBucketName
        urlRequest.key = key
        urlRequest.httpMethod = .GET
        urlRequest.expires = Date(timeIntervalSinceNow: expirationTime)
        
        logger.debug("[URL] Generating pre-signed URL for S3 object: bucket=\(attachmentBucketName), key=\(key), expires=\(expirationTime)s")
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[URL] Attempt \(attempt + 1)/\(maxAttempts) to generate pre-signed URL: \(key)")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                let presignedURL = try await withCheckedThrowingContinuation { continuation in
                    AWSS3PreSignedURLBuilder.default().getPreSignedURL(urlRequest).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                logger.info("[URL] Successfully generated pre-signed URL for: \(key)")
                return presignedURL
                
            } catch let error as NSError {
                logger.warning("[URL] S3 pre-signed URL generation failed for key \(key) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[URL] S3 pre-signed URL generation failed after \(attempt + 1) attempts for key \(key). Will not retry.")
                    return nil
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[URL] An unexpected error occurred during S3 pre-signed URL generation for key \(key): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return nil
                }
                
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[URL] Reached end of generatePresignedURL function unexpectedly for key \(key).")
        return nil
    }
    
    // MARK: - Public API: File Deletion
    
    /// Deletes a file from S3
    /// - Parameters:
    ///   - key: The object key/path in S3
    ///   - retryCount: Optional maximum number of attempts
    /// - Returns: Boolean indicating success
    public func deleteFile(key: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        
        // Create delete request
        guard let deleteRequest = AWSS3DeleteObjectRequest() else {
            logger.error("[Delete] Failed to create DeleteObjectRequest for key: \(key)")
            return false
        }
        
        deleteRequest.bucket = attachmentBucketName
        deleteRequest.key = key
        
        logger.info("[Delete] Deleting file from S3: bucket=\(attachmentBucketName), key=\(key)")
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("[Delete] Attempt \(attempt + 1)/\(maxAttempts) to delete file: \(key)")
                
                // Using try-await pattern to make AWS SDK work with structured concurrency
                _ = try await withCheckedThrowingContinuation { continuation in
                    client.deleteObject(deleteRequest).continueWith { task in
                        if let error = task.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: task.result!)
                        }
                        return nil
                    }
                }
                
                logger.info("[Delete] Successfully deleted file from S3: \(key)")
                return true
                
            } catch let error as NSError {
                logger.warning("[Delete] S3 deleteObject failed for key \(key) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                
                guard isRetryableAWSError(error), attempt < maxAttempts - 1 else {
                    logger.error("[Delete] S3 deleteObject failed after \(attempt + 1) attempts for key \(key). Will not retry.")
                    return false
                }
                
                // Apply exponential backoff with jitter
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
            } catch {
                logger.error("[Delete] An unexpected error occurred during S3 deleteObject for key \(key): \(error)")
                
                if attempt >= maxAttempts - 1 {
                    return false
                }
                
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        logger.error("[Delete] Reached end of deleteFile function unexpectedly for key \(key).")
        return false
    }
    
    // MARK: - Helper Methods
    
    /// Checks if an NSError from AWS SDK is retryable.
    /// - Parameter error: The error to check
    /// - Returns: Boolean indicating whether the error is retryable
    private func isRetryableAWSError(_ error: NSError) -> Bool {
        // Standard AWS service errors
        if error.domain == AWSServiceErrorDomain {
            switch AWSServiceErrorType(rawValue: error.code) {
            case .throttling, .requestTimeout, .serviceUnavailable, .internalFailure:
                return true
            default:
                return false
            }
        }
        
        // S3-specific errors
        if error.domain == AWSS3ErrorDomain {
            switch AWSS3ErrorType(rawValue: error.code) {
            case .serviceUnavailable, .slowDown, .internalError, .requestTimeout:
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
    
    /// Generates a unique key for storing a file
    /// - Parameters:
    ///   - prefix: Optional folder prefix
    ///   - fileExtension: Optional file extension
    /// - Returns: A unique S3 key
    public func generateUniqueKey(prefix: String? = nil, fileExtension: String? = nil) -> String {
        let uuid = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        
        var key = uuid + "-" + String(timestamp)
        
        if let ext = fileExtension?.trimmingCharacters(in: .whitespaces), !ext.isEmpty {
            // Ensure extension starts with a dot
            let extension = ext.hasPrefix(".") ? ext : ".\(ext)"
            key += extension
        }
        
        if let prefix = prefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty {
            // Ensure prefix ends with a slash
            let folderPrefix = prefix.hasSuffix("/") ? prefix : "\(prefix)/"
            key = folderPrefix + key
        }
        
        return key
    }
}

// MARK: - MIME Type Detection

/// Helper class for detecting MIME types of file data
fileprivate class MIMETypeDetector {
    /// Default MIME type if detection fails
    private let defaultMIMEType = "application/octet-stream"
    
    /// Common file signatures for binary detection
    private let signatures: [(signature: [UInt8], mimeType: String)] = [
        // JPEG
        (signature: [0xFF, 0xD8, 0xFF], mimeType: "image/jpeg"),
        // PNG
        (signature: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], mimeType: "image/png"),
        // GIF
        (signature: [0x47, 0x49, 0x46, 0x38], mimeType: "image/gif"),
        // PDF
        (signature: [0x25, 0x50, 0x44, 0x46], mimeType: "application/pdf"),
        // ZIP
        (signature: [0x50, 0x4B, 0x03, 0x04], mimeType: "application/zip"),
        // MP4
        (signature: [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70], mimeType: "video/mp4"),
    ]
    
    /// Detect MIME type from file data
    /// - Parameter data: The data to analyze
    /// - Returns: MIME type string
    func detectMIMEType(for data: Data) -> String {
        // First check if the data has a signature we recognize
        if let mimeType = detectFromSignature(data) {
            return mimeType
        }
        
        // Try to use UTType if available (iOS 14+)
        if #available(iOS 14.0, *) {
            // Create a hash of the first few bytes to use as a "filename"
            // This helps UTType make a better guess
            let hashData = data.prefix(64)
            let hash = SHA256.hash(data: hashData)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
            
            if let type = UTType(filenameExtension: hashString),
               let mimeType = type.preferredMIMEType {
                return mimeType
            }
        }
        
        // Try to determine if it's text
        if isLikelyText(data) {
            return "text/plain"
        }
        
        // Default
        return defaultMIMEType
    }
    
    /// Detects MIME type from known binary signatures
    /// - Parameter data: The data to check
    /// - Returns: MIME type if found, nil otherwise
    private func detectFromSignature(_ data: Data) -> String? {
        guard data.count >= 4 else {
            return nil
        }
        
        let bytes = [UInt8](data.prefix(16))
        
        for (signature, mimeType) in signatures {
            guard signature.count <= bytes.count else {
                continue
            }
            
            var match = true
            for i in 0..<signature.count {
                if signature[i] != bytes[i] {
                    match = false
                    break
                }
            }
            
            if match {
                return mimeType
            }
        }
        
        return nil
    }
    
    /// Tries to determine if the data is likely text
    /// - Parameter data: The data to check
    /// - Returns: True if it's likely text
    private func isLikelyText(_ data: Data) -> Bool {
        // Sample the first 512 bytes
        let sampleSize = min(512, data.count)
        let sample = data.prefix(sampleSize)
        
        // Count printable ASCII characters
        var printableCount = 0
        var nullCount = 0
        
        for byte in sample {
            if byte == 0 {
                nullCount += 1
            } else if (byte >= 32 && byte <= 126) || byte == 9 || byte == 10 || byte == 13 {
                printableCount += 1
            }
        }
        
        // If we have nulls, probably not text
        if nullCount > 0 {
            return false
        }
        
        // If more than 90% are printable ASCII, likely text
        return Double(printableCount) / Double(sampleSize) > 0.9
    }
}
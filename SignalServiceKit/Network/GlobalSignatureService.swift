//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import Logging
// Assuming APIGatewayClient is in the same module or imported correctly
// If APIGatewayClient.swift is in a different module, add the correct import here.
// Example: import MyNetworkModule

// Import necessary services for batch operations
import DuplicateContentDetection // Assuming S3toDynamoDBImporter and BatchImportJobTracker are here


/// Manages global content hash signature checks and storage via an API Gateway.
/// Includes retry logic with exponential backoff for API operations and batch processing capabilities.
public final class GlobalSignatureService {
    // MARK: - Singleton

    /// Shared instance for accessing the service throughout the app
    public static let shared = GlobalSignatureService()

    // MARK: - Types

    /// Represents the status of a batch import job.
    public struct JobStatus: Codable {
        public enum Status: String, Codable {
            case pending, processing, completed, failed, cancelled
        }

        public let jobId: String
        public let status: Status
        public let progress: Double // 0.0 to 1.0
        public let errorMessage: String?
        public let createdAt: Date
        public let updatedAt: Date

        // Custom mapping from tracker's status type if needed
        init(jobId: String, status: BatchImportJobTracker.JobStatusData.Status, progress: Double, errorMessage: String?, createdAt: Date, updatedAt: Date) {
            self.jobId = jobId
            self.status = JobStatus.Status(rawValue: status.rawValue) ?? .failed // Map to our enum
            self.progress = progress
            self.errorMessage = errorMessage
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    // MARK: - Private Properties

    private let apiClient: APIGatewayClient
    private let s3Importer = S3toDynamoDBImporter.shared
    // Assuming BatchImportJobTracker exists for status checking
    private let jobTracker = BatchImportJobTracker.shared
    private let logger = Logger(label: "org.signal.GlobalSignatureService")

    // Field names from AWSConfig, still needed for request/response bodies
    private let hashFieldName = AWSConfig.hashFieldName
    private let timestampFieldName = AWSConfig.timestampFieldName
    private let ttlFieldName = AWSConfig.ttlFieldName
    private let defaultRetryCount = 3

    // MARK: - Metrics Tracking

    private var containsApiCalls: Int = 0
    private var storeApiCalls: Int = 0
    private var deleteApiCalls: Int = 0
    private var batchContainsApiCalls: Int = 0
    private var batchImportApiCalls: Int = 0

    private var containsSuccessCount: Int = 0
    private var storeSuccessCount: Int = 0
    private var deleteSuccessCount: Int = 0
    private var batchContainsSuccessCount: Int = 0
    private var batchImportSuccessCount: Int = 0

    private var totalHashesChecked: Int = 0
    private var totalHashesStored: Int = 0
    private var totalHashesDeleted: Int = 0
    private var totalHashesCheckedInBatches: Int = 0
    private var totalHashesImported: Int = 0

    private var totalContainsDuration: TimeInterval = 0
    private var totalStoreDuration: TimeInterval = 0
    private var totalDeleteDuration: TimeInterval = 0
    private var totalBatchContainsDuration: TimeInterval = 0
    private var totalBatchImportDuration: TimeInterval = 0

    private let metricsLock = NSLock() // Lock for thread-safe metric updates

    // MARK: - Initialization

    /// Private initializer for singleton
    private init() {
        self.apiClient = APIGatewayClient.shared
        logger.info("Initialized GlobalSignatureService with actual API Gateway client.")
    }

    // MARK: - Helpers


    /// Calculates the TTL timestamp (Unix epoch) based on the configured duration.
    private func calculateTTLTimestamp() -> Int {
        let currentDate = Date()
        return Int(currentDate.timeIntervalSince1970) + (AWSConfig.defaultTTLInDays * 24 * 60 * 60)
    }

    /// Checks if an NSError from HTTP or network operations is retryable.
    private func isRetryableAPIError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
             if let httpStatusCode = error.userInfo[APIGatewayClient.HTTPStatusCodeErrorKey] as? Int {
                 switch httpStatusCode {
                 case 429, // Too Many Requests (Often transient)
                      500, 502, 503, 504: // Server Errors (Internal Server Error, Bad Gateway, Service Unavailable, Gateway Timeout)
                     return true
                 default:
                     break // Check other domains or URL error codes
                 }
              }

            // Network connection errors are also retryable
            switch error.code {
            case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return true
            default:
                return false // Other URL errors are likely not retryable (e.g. NSURLErrorCancelled, NSURLErrorUnsupportedURL)
            }
        }

        // You might add checks for other specific error domains if needed,
        // e.g., AWSServiceErrorDomain for service-specific errors if not proxied by Gateway
        // if error.domain == AWSServiceErrorDomain { ... }


        // Default to non-retryable for unknown errors
        return false
    }

    /// Executes a given async operation with retry logic.
    private func executeWithRetry<T>(
        maxAttempts: Int,
        operationType: String,
        key: String? = nil, // Optional key for logging context
        operation: @escaping () async throws -> T
    ) async -> Result<T, Error> {
        for attempt in 0..<maxAttempts {
            let startTime = Date()
            do {
                logger.debug("[\(operationType)] Attempt \(attempt + 1)/\(maxAttempts)... Key: \(key ?? "N/A")")
                let result = try await operation()
                let duration = Date().timeIntervalSince(startTime)
                // Log success and duration (could also aggregate metrics here)
                logger.trace("[\(operationType)] Attempt \(attempt + 1) succeeded in \(duration)s. Key: \(key ?? "N/A")")
                // Track success metric (specific metric tracking done in public methods)
                return .success(result)
            } catch let error as NSError {
                let duration = Date().timeIntervalSince(startTime)
                logger.warning("[\(operationType)] Attempt \(attempt + 1)/\(maxAttempts) failed in \(duration)s: \(error.localizedDescription), Code: \(error.code), Domain: \(error.domain). Key: \(key ?? "N/A")")

                guard isRetryableAPIError(error), attempt < maxAttempts - 1 else {
                    logger.error("[\(operationType)] Operation failed after \(attempt + 1) attempts. Will not retry. Key: \(key ?? "N/A")")
                    // Track failure metric (specific metric tracking done in public methods)
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
        return .failure(NSError(domain: "GlobalSignatureService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Exhausted retries unexpectedly"]))
    }

    // MARK: - Public API: Single Hash Operations

    /// Checks if a content hash exists via the GetTag API Gateway endpoint.
    public func contains(_ hash: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        let endpointUrl = AWSConfig.getEndpoint(for: .checkHash)
        let endpointPath = "/signatures/\(hash.urlQueryPercentEncoded())"
        let operationType = "CheckHash"
        let startTime = Date()

        metricsLock.lock()
        containsApiCalls += 1
        totalHashesChecked += 1
        metricsLock.unlock()

        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: hash.prefix(8).description) {
            let _: EmptyResponse = try await self.apiClient.get(path: endpointPath, endpointUrl: endpointUrl)
            return true // If no error (implies 200 OK), hash exists
        }

        let duration = Date().timeIntervalSince(startTime)
        metricsLock.lock()
        totalContainsDuration += duration
        metricsLock.unlock()

        switch result {
        case .success:
            logger.info("[\(operationType)] Successfully checked hash \(hash.prefix(8)): Found")
            metricsLock.lock()
            containsSuccessCount += 1
            metricsLock.unlock()
            return true
        case .failure(let error as NSError):
            if let statusCode = error.userInfo[APIGatewayClient.HTTPStatusCodeErrorKey] as? Int, statusCode == 404 {
                logger.info("[\(operationType)] Successfully checked hash \(hash.prefix(8)): Not Found (404)")
                // Treat 404 as success in terms of operation completion, but hash doesn't exist
                metricsLock.lock()
                containsSuccessCount += 1 // The check itself succeeded
                metricsLock.unlock()
                return false
            }
            // Logged already by executeWithRetry
            return false
        case .failure(let error):
            // Logged already by executeWithRetry
             logger.error("[\(operationType)] Unexpected non-NSError during check: \(error)")
            return false
        }
    }

    /// Stores a content hash via the general operations API Gateway endpoint.
    @discardableResult
    public func store(_ hash: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        let endpointUrl = AWSConfig.getEndpoint(for: .storeHash)
        let endpointPath = "/signatures"
        let operationType = "StoreHash"
        let startTime = Date()

        let requestBody: [String: Any] = [
            hashFieldName: hash,
            timestampFieldName: ISO8601DateFormatter().string(from: Date()),
            ttlFieldName: calculateTTLTimestamp()
        ]

        metricsLock.lock()
        storeApiCalls += 1
        metricsLock.unlock()

        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: hash.prefix(8).description) {
            let _: EmptyResponse = try await self.apiClient.post(path: endpointPath, body: requestBody, endpointUrl: endpointUrl)
            return true // Return true on success
        }

        let duration = Date().timeIntervalSince(startTime)
        metricsLock.lock()
        totalStoreDuration += duration
        metricsLock.unlock()

        switch result {
        case .success:
            logger.info("[\(operationType)] Successfully stored hash \(hash.prefix(8))")
            metricsLock.lock()
            storeSuccessCount += 1
            totalHashesStored += 1
            metricsLock.unlock()
            return true
        case .failure(let error as NSError):
            if let statusCode = error.userInfo[APIGatewayClient.HTTPStatusCodeErrorKey] as? Int, statusCode == 409 {
                logger.info("[\(operationType)] Hash \(hash.prefix(8)) already exists (409). Considered successful.")
                metricsLock.lock()
                storeSuccessCount += 1 // Treat 409 as success for idempotency
                metricsLock.unlock()
                return true
            }
            // Logged already by executeWithRetry
            return false
         case .failure(let error):
             logger.error("[\(operationType)] Unexpected non-NSError during store: \(error)")
            return false
        }
    }

    /// Deletes a content hash via the general operations API Gateway endpoint.
    @discardableResult
    public func delete(_ hash: String, retryCount: Int? = nil) async -> Bool {
        let maxAttempts = retryCount ?? defaultRetryCount
        let endpointUrl = AWSConfig.getEndpoint(for: .deleteHash)
        let endpointPath = "/signatures/\(hash.urlQueryPercentEncoded())"
        let operationType = "DeleteHash"
        let startTime = Date()

        metricsLock.lock()
        deleteApiCalls += 1
        metricsLock.unlock()

        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType, key: hash.prefix(8).description) {
            let _: EmptyResponse = try await self.apiClient.delete(path: endpointPath, endpointUrl: endpointUrl)
            return true // Return true on success
        }

        let duration = Date().timeIntervalSince(startTime)
        metricsLock.lock()
        totalDeleteDuration += duration
        metricsLock.unlock()

        switch result {
        case .success:
            logger.info("[\(operationType)] Successfully deleted hash \(hash.prefix(8))")
            metricsLock.lock()
            deleteSuccessCount += 1
            totalHashesDeleted += 1
            metricsLock.unlock()
            return true
        case .failure(let error as NSError):
             if let statusCode = error.userInfo[APIGatewayClient.HTTPStatusCodeErrorKey] as? Int, statusCode == 404 {
                 logger.info("[\(operationType)] Hash \(hash.prefix(8)) not found during delete (404). Considered successful.")
                 metricsLock.lock()
                 deleteSuccessCount += 1 // Treat 404 as success
                 metricsLock.unlock()
                 return true
             }
            // Logged already by executeWithRetry
            return false
        case .failure(let error):
            logger.error("[\(operationType)] Unexpected non-NSError during delete: \(error)")
            return false
        }
    }

    // MARK: - Batch Operations

    /// Initiates a batch import process for a list of content hashes using S3 and Lambda.
    ///
    /// This method uploads the provided hashes to S3 and triggers a Lambda function
    /// managed by `S3toDynamoDBImporter` to import them into DynamoDB.
    /// Progress reporting is handled via logging for now.
    ///
    /// - Parameters:
    ///   - hashes: An array of Base64 encoded content hash strings to import.
    ///   - format: The format for the S3 upload (e.g., .csv, .json). Defaults to .csv.
    ///   - progress: A closure to report progress updates (e.g., percentage complete). Placeholder.
    /// - Returns: A unique Job ID string if the import job was successfully initiated, otherwise nil.
    /// - Throws: Errors related to S3 upload or Lambda invocation failures after exhausting retries.
    public func batchImportHashes(
        hashes: [String],
        format: S3toDynamoDBImporter.ImportFormat = .csv,
        progress: ((Double) -> Void)? = nil
    ) async -> String? {
        let operationType = "BatchImport"
        let startTime = Date()

        metricsLock.lock()
        batchImportApiCalls += 1
        metricsLock.unlock()

        logger.info("[\(operationType)] Starting batch import for \(hashes.count) hashes using \(format) format.")

        guard !hashes.isEmpty else {
            logger.warning("[\(operationType)] Attempted batch import with empty hash list.")
            return nil
        }

        progress?(0.0)
        logger.debug("[\(operationType)] Progress: 0.0")

        do {
            // Delegate to the importer service
            // Initiate the import process using S3toDynamoDBImporter.
            // Assumes initiateImport handles S3 upload, Lambda trigger, and returns a job ID.
            // Pass the progress closure to the importer if it supports it.
            let jobId = try await s3Importer.initiateImport(hashes: hashes, format: format, progress: progress)

            let duration = Date().timeIntervalSince(startTime)
            metricsLock.lock()
            totalBatchImportDuration += duration
            if jobId != nil { // Assume success if a job ID was returned
               batchImportSuccessCount += 1
               totalHashesImported += hashes.count
            }
            metricsLock.unlock()

            if jobId != nil {
                logger.info("[\(operationType)] Successfully initiated batch import job with ID: \(jobId!). Duration: \(duration)s")
            } else {
                 logger.error("[\(operationType)] Failed to initiate batch import job (no job ID returned). Duration: \(duration)s")
            }

            progress?(1.0) // Ensure final progress is reported
            return jobId

        } catch let error as NSError {
            let duration = Date().timeIntervalSince(startTime)
            logger.error("[\(operationType)] Failed to initiate batch import after \(duration)s: \(error.localizedDescription). Domain: \(error.domain), Code: \(error.code)")
            progress?(1.0) // Report completion even on error
            metricsLock.lock()
            totalBatchImportDuration += duration // Still record duration
            // Failure count is implicitly (batchImportApiCalls - batchImportSuccessCount)
            metricsLock.unlock()
            return nil
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            logger.error("[\(operationType)] An unexpected error occurred during batch import initiation after \(duration)s: \(error)")
            progress?(1.0)
            metricsLock.lock()
            totalBatchImportDuration += duration
            metricsLock.unlock()
            return nil
        }
    }

    /// Checks if multiple content hashes exist via the API Gateway using a batch operation.
    /// NOTE: Assumes the API supports batch checks and handles pagination internally or has a reasonable limit.
    /// Future improvement: Implement client-side pagination if API doesn't support large batches.
    public func batchContains(hashes: [String], retryCount: Int? = nil) async -> [String: Bool]? {
        let maxAttempts = retryCount ?? defaultRetryCount
        let operationType = "BatchCheckHash"
        // Use appropriate endpoint - assuming a dedicated batch endpoint exists or the checkHash endpoint handles batches.
        // For this example, we assume a POST request to a specific batch path on the primary endpoint.
        let endpointUrl = AWSConfig.getEndpoint(for: .checkHash) // Or a new .batchCheckHash type if applicable
        let endpointPath = "/signatures/batch-check" // Assumed path for batch checking
        let startTime = Date()

        guard !hashes.isEmpty else {
            logger.warning("[\(operationType)] Attempted batch check with empty hash list.")
            return [:] // Return empty dictionary for empty input
        }

        // Note: If hashes.count is very large, we might need to split it into multiple requests here.
        // For now, assuming the API handles the provided batch size. Add check/split later if needed.
        if hashes.count > 1000 { // Example limit
            logger.warning("[\(operationType)] Large batch size (\(hashes.count)). Consider client-side pagination.")
        }

        let requestBody: [String: Any] = ["hashes": hashes]

        metricsLock.lock()
        batchContainsApiCalls += 1
        metricsLock.unlock()

        let result = await executeWithRetry(maxAttempts: maxAttempts, operationType: operationType) {
            struct BatchContainsResponse: Decodable {
                let results: [String: Bool]
            }
            let response: BatchContainsResponse = try await self.apiClient.post(path: endpointPath, body: requestBody, endpointUrl: endpointUrl)
            return response.results
        }

        let duration = Date().timeIntervalSince(startTime)
        metricsLock.lock()
        totalBatchContainsDuration += duration
        metricsLock.unlock()

        switch result {
        case .success(let resultsDict):
            logger.info("[\(operationType)] Successfully batch checked \(hashes.count) hashes. Found: \(resultsDict.filter { $1 }.count). Duration: \(duration)s")
            metricsLock.lock()
            batchContainsSuccessCount += 1
            totalHashesCheckedInBatches += hashes.count
            metricsLock.unlock()
            return resultsDict
        case .failure:
            // Error already logged by executeWithRetry
            return nil
        }
    }

    // MARK: - Job Status Tracking

    /// Retrieves the status of a previously initiated batch import job.
    /// - Parameter jobId: The unique ID of the batch import job.
    /// - Returns: A `JobStatus` object containing the current status, or nil if the job ID is invalid or status retrieval fails.
    public func getJobStatus(jobId: String) async -> JobStatus? {
        let operationType = "GetJobStatus"
        logger.debug("[\(operationType)] Checking status for job ID: \(jobId)")

        // Delegate status retrieval to the BatchImportJobTracker
        do {
            // Using `try?` as status retrieval might fail for invalid IDs or network issues
            let trackerStatus = try? await jobTracker.getStatus(for: jobId)
            if let trackerStatus = trackerStatus {
                 logger.info("[\(operationType)] Successfully retrieved status for job \(jobId): \(trackerStatus.status.rawValue)")
                 // Map the tracker's status structure to our public JobStatus structure
                 return JobStatus(
                     jobId: trackerStatus.jobId,
                     status: trackerStatus.status, // Assuming JobStatusData.Status can be mapped directly
                     progress: trackerStatus.progress,
                     errorMessage: trackerStatus.errorMessage,
                     createdAt: trackerStatus.createdAt,
                     updatedAt: trackerStatus.updatedAt
                 )
            } else {
                 logger.warning("[\(operationType)] Job ID \(jobId) not found or status retrieval failed via tracker.")
                 return nil
            }
        } catch {
             logger.error("[\(operationType)] Error retrieving status for job \(jobId) via tracker: \(error)")
             return nil
        }
    }

    /// Attempts to cancel a running batch import job.
    /// - Parameter jobId: The unique ID of the batch import job to cancel.
    /// - Returns: Boolean indicating if the cancellation request was successfully submitted.
    public func cancelBatchImportJob(jobId: String) async -> Bool {
         let operationType = "CancelJob"
         logger.info("[\(operationType)] Requesting cancellation for job ID: \(jobId)")

         // Delegate cancellation request to the tracker
         do {
             let success = try await jobTracker.requestCancellation(for: jobId)
             if success {
                  logger.info("[\(operationType)] Cancellation request submitted successfully for job \(jobId).")
             } else {
                  logger.warning("[\(operationType)] Failed to submit cancellation request for job \(jobId) (job might be finished or non-existent).")
             }
             return success
         } catch {
             logger.error("[\(operationType)] Error requesting cancellation for job \(jobId): \(error)")
             return false
         }
     }


    // MARK: - Metrics Accessors

    /// Returns a dictionary containing various performance and usage metrics.
    public func getMetrics() -> [String: Any] {
        metricsLock.lock()
        defer { metricsLock.unlock() }

        let containsFailCount = containsApiCalls - containsSuccessCount
        let storeFailCount = storeApiCalls - storeSuccessCount
        let deleteFailCount = deleteApiCalls - deleteSuccessCount
        let batchContainsFailCount = batchContainsApiCalls - batchContainsSuccessCount
        let batchImportFailCount = batchImportApiCalls - batchImportSuccessCount

        return [
            "singleContains": [
                "calls": containsApiCalls, "success": containsSuccessCount, "failed": containsFailCount,
                "totalHashes": totalHashesChecked, "avgDuration": containsApiCalls > 0 ? totalContainsDuration / Double(containsApiCalls) : 0
            ],
            "singleStore": [
                "calls": storeApiCalls, "success": storeSuccessCount, "failed": storeFailCount,
                "totalHashes": totalHashesStored, "avgDuration": storeApiCalls > 0 ? totalStoreDuration / Double(storeApiCalls) : 0
            ],
            "singleDelete": [
                "calls": deleteApiCalls, "success": deleteSuccessCount, "failed": deleteFailCount,
                "totalHashes": totalHashesDeleted, "avgDuration": deleteApiCalls > 0 ? totalDeleteDuration / Double(deleteApiCalls) : 0
            ],
            "batchContains": [
                "calls": batchContainsApiCalls, "success": batchContainsSuccessCount, "failed": batchContainsFailCount,
                "totalHashes": totalHashesCheckedInBatches, "avgDuration": batchContainsApiCalls > 0 ? totalBatchContainsDuration / Double(batchContainsApiCalls) : 0
            ],
            "batchImport": [
                "calls": batchImportApiCalls, "success": batchImportSuccessCount, "failed": batchImportFailCount,
                "totalHashes": totalHashesImported, "avgDuration": batchImportApiCalls > 0 ? totalBatchImportDuration / Double(batchImportApiCalls) : 0
            ]
        ]
    }

    /// Resets all internal metrics counters to zero.
    public func resetMetrics() {
        metricsLock.lock()
        defer { metricsLock.unlock() }

        containsApiCalls = 0
        storeApiCalls = 0
        deleteApiCalls = 0
        batchContainsApiCalls = 0
        batchImportApiCalls = 0

        containsSuccessCount = 0
        storeSuccessCount = 0
        deleteSuccessCount = 0
        batchContainsSuccessCount = 0
        batchImportSuccessCount = 0

        totalHashesChecked = 0
        totalHashesStored = 0
        totalHashesDeleted = 0
        totalHashesCheckedInBatches = 0
        totalHashesImported = 0

        totalContainsDuration = 0
        totalStoreDuration = 0
        totalDeleteDuration = 0
        totalBatchContainsDuration = 0
        totalBatchImportDuration = 0

        logger.info("Reset GlobalSignatureService API call metrics.")
    }
}

// MARK: - Supporting Types

// Helper struct for empty API responses if APIGatewayClient expects a Decodable type but the API returns an empty body (e.g., 204 No Content).
// This should ideally be defined in or imported from the module containing APIGatewayClient.
struct EmptyResponse: Decodable {}

// Helper extension for URL encoding path components
// This should ideally be in a common utility file or imported.
extension String {
    /// Returns a new string containing the percent-escaped characters from the string
    /// that are not in the allowedCharacters set, suitable for use as a URL path component.
    /// Uses a more aggressive set than standard URL encoding for paths.
    func urlQueryPercentEncoded() -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~") // Characters typically allowed unescaped in paths
        let encoded = self.addingPercentEncoding(withAllowedCharacters: allowed)
        return encoded ?? self // Fallback to original string if encoding fails
    }
}

// NOTE: The placeholder APIGatewayClient class definition has been removed.
// It is assumed that the actual APIGatewayClient class exists and is accessible.
// Also assumed S3toDynamoDBImporter exists and is accessible.
// And BatchImportJobTracker exists and is accessible.
// And AWSConfig.APIOperationType is accessible.

// In DuplicateContentDetection/Services/S3toDynamoDBImporter.swift
import Foundation
import Logging

public class S3toDynamoDBImporter {
    public static let shared = S3toDynamoDBImporter()
    private let logger = Logger(label: "org.signal.S3toDynamoDBImporter")

    public enum ImportFormat { case csv, json }

    private init() {}

    /// Placeholder: Initiates the S3 upload and Lambda trigger.
    public func initiateImport(
        hashes: [String],
        format: ImportFormat,
        progress: ((Double) -> Void)? = nil // Accept progress closure
    ) async throws -> String? {
        let jobId = UUID().uuidString
        logger.info("Simulating S3 upload and Lambda trigger for \(hashes.count) hashes (format: \(format)). Job ID: \(jobId)")

        // Simulate work and progress
        progress?(0.1)
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        progress?(0.5)
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        // Simulate potential failure
        if hashes.contains("FAIL_IMPORT") {
             logger.error("Simulated import failure.")
             throw NSError(domain: "S3ImporterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated S3/Lambda import failure"])
        }

        progress?(1.0)
        logger.info("Simulated import process complete for job ID: \(jobId)")

        // In real implementation:
        // 1. Generate CSV/JSON data
        // 2. Upload data to S3 using S3Service
        // 3. Trigger Lambda function using LambdaService
        // 4. Create job entry in BatchImportJobTracker
        // 5. Return Job ID

        // For now, register a mock job status
        await BatchImportJobTracker.shared.registerMockJob(
             jobId: jobId,
             status: .completed,
             progress: 1.0
        )

        return jobId
    }
}

// In DuplicateContentDetection/Services/BatchImportJobTracker.swift
import Foundation
import Logging

public class BatchImportJobTracker {
    public static let shared = BatchImportJobTracker()
    private let logger = Logger(label: "org.signal.BatchImportJobTracker")

    // Simple in-memory store for mock status
    private var jobStatuses: [String: JobStatusData] = [:]
    private let lock = NSLock()

    public struct JobStatusData {
         public enum Status: String { case pending, processing, completed, failed, cancelled }
         public let jobId: String
         public var status: Status
         public var progress: Double
         public var errorMessage: String?
         public let createdAt: Date
         public var updatedAt: Date
     }


    private init() {}

    /// Placeholder: Retrieves the status of a job.
    public func getStatus(for jobId: String) async throws -> JobStatusData? {
        logger.debug("Checking status for job ID: \(jobId)")
        lock.lock()
        defer { lock.unlock() }
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        return jobStatuses[jobId]
    }

    /// Placeholder: Requests cancellation of a job.
     public func requestCancellation(for jobId: String) async throws -> Bool {
         logger.info("Requesting cancellation for job ID: \(jobId)")
         lock.lock()
         defer { lock.unlock() }
         // Simulate finding and updating status
         if var job = jobStatuses[jobId], job.status == .processing || job.status == .pending {
             job.status = .cancelled
             job.updatedAt = Date()
             jobStatuses[jobId] = job
             logger.info("Marked job \(jobId) as cancelled.")
             return true
         } else {
             logger.warning("Job \(jobId) not found or cannot be cancelled (current status: \(jobStatuses[jobId]?.status.rawValue ?? "unknown")).")
             return false
         }
     }


    // --- Mocking Support ---
     public func registerMockJob(jobId: String, status: JobStatusData.Status, progress: Double, errorMessage: String? = nil) {
          lock.lock()
          let now = Date()
          jobStatuses[jobId] = JobStatusData(
               jobId: jobId,
               status: status,
               progress: progress,
               errorMessage: errorMessage,
               createdAt: now,
               updatedAt: now
          )
          lock.unlock()
          logger.info("Registered/Updated mock job \(jobId) with status \(status)")
     }

     public func clearMockJobs() {
          lock.lock()
          jobStatuses.removeAll()
          lock.unlock()
          logger.info("Cleared all mock jobs.")
     }

}
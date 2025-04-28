//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Logging
// AWSCore might not be directly needed here if using abstracted services
// import AWSCore

/// Service responsible for initiating and managing batch imports of content hashes from S3 to DynamoDB.
/// It orchestrates the process: formatting data, uploading to S3, triggering a Lambda function,
/// and tracking the job status via BatchImportJobTracker.
public class S3toDynamoDBImporter {

    // MARK: - Singleton
    public static let shared = S3toDynamoDBImporter()

    // MARK: - Types
    /// Defines the supported file formats for batch import data.
    public enum ImportFormat: String {
        case csv
        case json
    }

    // MARK: - Private Properties
    private let s3Service = S3Service.shared
    private let lambdaService = LambdaService.shared
    private let jobTracker = BatchImportJobTracker.shared // Assuming BatchImportJobTracker is accessible
    private let logger = Logger(label: "org.signal.S3toDynamoDBImporter")

    /// The S3 prefix (folder) where import files will be uploaded.
    private let s3ImportPrefix = "hash-imports/"

    /// Private initializer for singleton pattern.
    private init() {
        logger.info("Initialized S3toDynamoDBImporter.")
    }

    // MARK: - Public API: Import Initiation

    /// Initiates a batch import process for a list of content hashes.
    ///
    /// This method formats the provided hashes into the specified format (CSV or JSON),
    /// uploads the data to a unique key in S3 under the `hash-imports/` prefix,
    /// triggers the S3-to-DynamoDB Lambda function asynchronously, creates a job entry
    /// in the `BatchImportJobTracker`, and returns the unique Job ID.
    ///
    /// - Parameters:
    ///   - hashes: An array of Base64 encoded content hash strings to import.
    ///   - format: The format for the S3 upload file (`.csv` or `.json`). Defaults to `.csv`.
    ///   - progress: An optional closure that receives progress updates (0.0 to 1.0).
    ///               Note: This implementation simulates basic progress; real progress depends on Lambda/tracker feedback.
    /// - Returns: A unique Job ID string if the import job was successfully initiated, `nil` otherwise.
    /// - Throws: Errors related to data formatting, S3 upload, Lambda invocation, or job creation.
    public func initiateImport(
        hashes: [String],
        format: ImportFormat = .csv,
        progress: ((Double) -> Void)? = nil
    ) async throws -> String? {
        let operationType = "InitiateImport"
        let startTime = Date()
        logger.info("[\(operationType)] Starting batch import for \(hashes.count) hashes (Format: \(format.rawValue)).")
        progress?(0.0) // Start progress

        guard !hashes.isEmpty else {
            logger.warning("[\(operationType)] Input hash list is empty. Aborting.")
            throw ImportError.emptyInput
        }

        // 1. Format Data
        logger.debug("[\(operationType)] Formatting hash data...")
        let (formattedDataString, fileExtension) = formatData(hashes: hashes, format: format)
        guard let dataToUpload = formattedDataString.data(using: .utf8) else {
            logger.error("[\(operationType)] Failed to convert formatted string to Data.")
            throw ImportError.formattingFailed
        }
        progress?(0.1) // Progress after formatting

        // 2. Upload to S3
        logger.debug("[\(operationType)] Uploading formatted data to S3...")
        guard let s3Key = await s3Service.uploadHashData(
            data: dataToUpload,
            format: format, // Pass format for content type and key generation
            prefix: s3ImportPrefix
        ) else {
            logger.error("[\(operationType)] Failed to upload hash data to S3.")
            throw ImportError.s3UploadFailed
        }
        logger.info("[\(operationType)] Successfully uploaded hash data to S3: \(s3Key)")
        progress?(0.4) // Progress after S3 upload

        // 3. Trigger Lambda (Async Invocation)
        logger.debug("[\(operationType)] Triggering S3-to-DynamoDB Lambda function...")
        // The triggerS3toDynamoDBTransfer method now handles the specific Lambda ARN.
        // We use .event type for async invocation, expecting Bool result for submission status.
        // Pass S3 bucket name from S3Service configuration.
        let triggerSuccess: Bool? = await lambdaService.triggerS3toDynamoDBTransfer(
            s3BucketName: s3Service.attachmentBucketName, // Use bucket name from S3Service
            s3Key: s3Key,
            invocationType: .event // Asynchronous invocation
        )

        guard triggerSuccess == true else {
            logger.error("[\(operationType)] Failed to trigger S3-to-DynamoDB Lambda function.")
            // Consider adding cleanup: delete the uploaded S3 file if Lambda trigger fails.
            // _ = await s3Service.deleteFile(key: s3Key)
            throw ImportError.lambdaInvocationFailed
        }
        logger.info("[\(operationType)] Successfully submitted async invocation request for Lambda function.")
        progress?(0.7) // Progress after Lambda trigger

        // 4. Create Job in Tracker
        logger.debug("[\(operationType)] Creating job entry in BatchImportJobTracker...")
        do {
            // Assuming BatchImportJobTracker has a createJob method that takes relevant info and returns a Job ID.
            let jobId = try await jobTracker.createJob(
                associatedS3Key: s3Key,
                totalItems: hashes.count // Provide total count for progress calculation
            )
            logger.info("[\(operationType)] Successfully created job entry with ID: \(jobId)")
            progress?(1.0) // Final progress
            let duration = Date().timeIntervalSince(startTime)
             logger.info("[\(operationType)] Import initiation completed successfully in \(duration)s. Job ID: \(jobId)")
            return jobId
        } catch {
            logger.error("[\(operationType)] Failed to create job entry in tracker: \(error)")
            // More cleanup might be needed here depending on tracker guarantees
            throw ImportError.jobTrackingCreationFailed(underlyingError: error)
        }
    }

    // MARK: - Public API: Job Management

    /// Retrieves the status of a previously initiated batch import job.
    /// - Parameter jobId: The unique ID of the batch import job.
    /// - Returns: A `LambdaService.JobStatus` object containing the current status, or `nil` if the job is not found or status retrieval fails.
    public func checkJobStatus(jobId: String) async -> LambdaService.JobStatus? {
        // Delegate directly to LambdaService which uses BatchImportJobTracker internally.
        return await lambdaService.checkS3ToDynamoDBTransferStatus(jobId: jobId)
    }

    /// Attempts to cancel a running batch import job.
    /// - Parameter jobId: The unique ID of the batch import job to cancel.
    /// - Returns: `true` if the cancellation request was successfully submitted, `false` otherwise.
    public func cancelJob(jobId: String) async -> Bool {
        // Delegate cancellation request to BatchImportJobTracker.
        // Assuming BatchImportJobTracker provides the requestCancellation method.
        return await jobTracker.requestCancellation(for: jobId)
    }

    // MARK: - Private Helper Methods: Data Formatting

    /// Generates a CSV formatted string from an array of hashes.
    /// Includes a header row "ContentHash".
    private func generateCSV(from hashes: [String]) -> String {
        // Simple CSV with a header row
        return "ContentHash\n" + hashes.joined(separator: "\n")
    }

    /// Generates a JSON formatted string from an array of hashes.
    /// Creates a JSON array of strings.
    private func generateJSON(from hashes: [String]) -> String {
        // Serialize the array of strings into JSON data
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: hashes, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "[]" // Fallback to empty array string
        } catch {
            logger.error("Failed to serialize hashes to JSON: \(error)")
            return "[]" // Return empty array on error
        }
    }

    /// Formats hash data into the specified format (CSV or JSON).
    /// Returns the formatted string and the appropriate file extension.
    private func formatData(hashes: [String], format: ImportFormat) -> (data: String, fileExtension: String) {
        switch format {
        case .csv:
            return (data: generateCSV(from: hashes), fileExtension: "csv")
        case .json:
            return (data: generateJSON(from: hashes), fileExtension: "json")
        }
    }

    // MARK: - Error Handling

    /// Defines errors specific to the S3toDynamoDBImporter service.
    public enum ImportError: Error, LocalizedError {
        case emptyInput
        case formattingFailed
        case s3UploadFailed
        case lambdaInvocationFailed
        case jobTrackingCreationFailed(underlyingError: Error?)

        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "Input hash list cannot be empty."
            case .formattingFailed:
                return "Failed to format hash data for S3 upload."
            case .s3UploadFailed:
                return "Failed to upload formatted hash data to S3."
            case .lambdaInvocationFailed:
                return "Failed to trigger the S3-to-DynamoDB Lambda function."
            case .jobTrackingCreationFailed(let underlyingError):
                return "Failed to create job entry in tracker. \(underlyingError?.localizedDescription ?? "")"
            }
        }
    }
}

// MARK: - BatchImportJobTracker Extension (Assumed Methods)
// Extend the existing BatchImportJobTracker or ensure these methods exist.

extension BatchImportJobTracker {
    /// Creates a new job entry in the tracker.
    /// - Parameters:
    ///   - associatedS3Key: The S3 key associated with this import job.
    ///   - totalItems: The total number of items to be processed.
    /// - Returns: The unique Job ID.
    /// - Throws: Error if job creation fails.
    func createJob(associatedS3Key: String, totalItems: Int) async throws -> String {
        let jobId = UUID().uuidString // Generate a unique job ID
        let now = Date()
        let initialStatus = JobStatusData(
            jobId: jobId,
            status: .pending, // Start as pending
            progress: 0.0,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now,
            // Add associatedS3Key and totalItems if JobStatusData supports them
            associatedS3Key: associatedS3Key, // Assumed property
            totalItems: totalItems            // Assumed property
        )
        
        // In a real implementation, this would persist the status (e.g., in memory, DB, etc.)
        // For the mock, just store it in the dictionary.
        lock.lock()
        jobStatuses[jobId] = initialStatus
        lock.unlock()
        
        logger.info("Created new job tracker entry. Job ID: \(jobId), S3 Key: \(associatedS3Key), Items: \(totalItems)")
        return jobId
    }
}

// Add assumed properties to JobStatusData for compilation
// These should be added to the actual BatchImportJobTracker.JobStatusData struct
extension BatchImportJobTracker.JobStatusData {
     // Add these properties if they don't exist in the actual tracker struct
     // public var associatedS3Key: String? = nil
     // public var totalItems: Int? = nil
     
     // Dummy initializer to prevent compiler errors if the real one isn't accessible here
     // Remove this if the real struct and its init are correctly defined and accessible
     init(jobId: String, status: BatchImportJobTracker.JobStatusData.Status, progress: Double, errorMessage: String?, createdAt: Date, updatedAt: Date, associatedS3Key: String?, totalItems: Int?) {
         self.jobId = jobId
         self.status = status
         self.progress = progress
         self.errorMessage = errorMessage
         self.createdAt = createdAt
         self.updatedAt = updatedAt
         // self.associatedS3Key = associatedS3Key
         // self.totalItems = totalItems
     }
}
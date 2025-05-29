import Foundation
import AWSS3
import AWSCore
import AWSLambda
import UIKit
import SignalServiceKit

// MARK: - Result Types

public enum ScanResult {
    case allowed(tags: [String], s3URL: URL)
    case blocked(reason: String, tags: [String])
    case error(_ error: Error?)
}

// MARK: - Error Types

public enum ContentFilterError: Error, LocalizedError {
    case configurationError(String)
    case processingError(String)
    case uploadError(String)
    case analysisError(String)
    case duplicateError(String)
    case networkError
    case unknown
    
    public var errorDescription: String? {
        switch self {
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .processingError(let message):
            return "Processing error: \(message)"
        case .uploadError(let message):
            return "Upload error: \(message)"
        case .analysisError(let message):
            return "Analysis error: \(message)"
        case .duplicateError(let message):
            return message
        case .networkError:
            return "Network error"
        case .unknown:
            return "Unknown error"
        }
    }
}

// MARK: - ContentFilterService

@objc
public class ContentFilterService: NSObject {
    @objc
    public static let shared = ContentFilterService()
    
    private let s3Bucket: String
    private let lambdaFunctionName: String
    private let region: AWSRegionType
    private let duplicateThreshold: Int
    
    private override init() {
        // Load configuration from Info.plist
        guard let bucket = Bundle.main.object(forInfoDictionaryKey: "ContentFilterBucketName") as? String,
              let functionName = Bundle.main.object(forInfoDictionaryKey: "ContentFilterLambdaName") as? String,
              let regionString = Bundle.main.object(forInfoDictionaryKey: "AWSRegion") as? String,
              let threshold = Bundle.main.object(forInfoDictionaryKey: "DuplicateThreshold") as? Int else {
            fatalError("Missing AWS configuration in Info.plist")
        }
        
        self.s3Bucket = bucket
        self.lambdaFunctionName = functionName
        self.region = AWSRegionType(string: regionString) ?? .USEast1
        self.duplicateThreshold = threshold
        
        super.init()
    }
    
    // MARK: - Public Interface
    
    /// Main method that matches the expected interface
    public func scanAndUpload(imageData: Data, fileName: String) async -> ScanResult {
        do {
            // 1. Process image and compute hashes
            let (sha256Hash, perceptualHash) = try processImage(imageData)
            
            // 2. Check for duplicates
            let duplicateCheckResult = try await checkDuplicate(sha256Hash: sha256Hash, perceptualHash: perceptualHash)
            
            switch duplicateCheckResult {
            case .duplicate(let count):
                if count >= duplicateThreshold {
                    return .blocked(
                        reason: "Duplicate image detected",
                        tags: ["duplicate", "threshold_exceeded"]
                    )
                }
            case .notDuplicate:
                break
            case .error(let error):
                throw error
            }
            
            // 3. Generate S3 key with user identifier
            let userId = getUserIdentifier()
            let s3Key = "\(userId)/\(sha256Hash).jpg"
            
            // 4. Upload to S3
            let s3URL = try await uploadToS3(imageData: imageData, key: s3Key)
            
            // 5. Analyze content (can add more sophisticated analysis here)
            let tags = try await analyzeContent(
                s3Key: s3Key,
                sha256Hash: sha256Hash,
                perceptualHash: perceptualHash
            )
            
            // 6. Check if any tags indicate blocked content
            if tags.contains(where: { $0.hasPrefix("blocked:") }) {
                // Clean up S3 object if blocked
                try? await deleteS3Object(key: s3Key)
                
                let blockedReason = tags.first(where: { $0.hasPrefix("blocked:") })?
                    .replacingOccurrences(of: "blocked:", with: "") ?? "Content policy violation"
                
                return .blocked(reason: blockedReason, tags: tags)
            }
            
            return .allowed(tags: tags, s3URL: s3URL)
            
        } catch {
            Logger.error("ContentFilter error: \(error)")
            return .error(error)
        }
    }
    
    // MARK: - Private Methods
    
    private func processImage(_ imageData: Data) throws
        -> (sha256Hash: String, perceptualHash: String?) {
        guard let image = UIImage(data: imageData) else {
            throw ContentFilterError.processingError("Failed to create UIImage from data")
        }

        // ――― Cryptographic + perceptual hashes in one shot ―――
        let (sha256Hash, pHashHex) = try ImageHashing.hashes(for: image)
        return (sha256Hash, pHashHex)          // <- the tuple we need
    }
    
    private func getUserIdentifier() -> String {
        // Get the local user's ACI if available
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager
        if let localAci = tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci {
            return localAci.serviceIdString
        }
        // Fallback to a device-specific identifier
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    }
    
    // MARK: - Duplicate Check
    
    private enum DuplicateCheckResult {
        case duplicate(count: Int)
        case notDuplicate
        case error(Error)
    }
    
    private func checkDuplicate(sha256Hash: String, perceptualHash: String?) async throws -> DuplicateCheckResult {
        let lambda = AWSLambda.default()
        
        let payload: [String: Any] = [
            "action": "checkDuplicate",
            "sha256Hash": sha256Hash,
            "perceptualHash": perceptualHash ?? "",
            "threshold": duplicateThreshold
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        
        let request = AWSLambdaInvocationRequest()!
        request.functionName = lambdaFunctionName
        request.invocationType = .requestResponse
        request.payload = jsonData
        
        let result = try await lambda.invoke(request)
        
        guard let responseData = result.payload as? Data else {
            return .error(ContentFilterError.analysisError("Lambda payload was not Data"))
        }
        
        guard let response = try? JSONSerialization.jsonObject(with: responseData,
                                                       options: []) as? [String: Any] else {
            return .error(ContentFilterError.analysisError("Invalid Lambda response"))
        }
        
        if let isDuplicate = response["isDuplicate"] as? Bool,
           let count = response["count"] as? Int {
            return isDuplicate ? .duplicate(count: count) : .notDuplicate
        }
        
        return .error(ContentFilterError.analysisError("Missing duplicate check data"))
    }
    
    // MARK: - S3 Operations
    
    private func uploadToS3(imageData: Data, key: String) async throws -> URL {
        let transferUtility = AWSS3TransferUtility.default()
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            transferUtility.uploadData(
                imageData,
                bucket: s3Bucket,
                key: key,
                contentType: "image/jpeg",
                expression: nil
            ) { task, error in
                if let error = error {
                    continuation.resume(throwing: ContentFilterError.uploadError(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }.continueWith { _ in
                return nil
            }
        }
        
        // Construct the S3 URL
        let s3URL = URL(string: "https://\(s3Bucket).s3.amazonaws.com/\(key)")!
        return s3URL
    }
    
    private func deleteS3Object(key: String) async throws {
        let s3 = AWSS3.default()
        let deleteRequest = AWSS3DeleteObjectRequest()!
        deleteRequest.bucket = s3Bucket
        deleteRequest.key = key
        
        _ = try await s3.deleteObject(deleteRequest)
    }
    
    // MARK: - Content Analysis
    
    private func analyzeContent(s3Key: String, sha256Hash: String, perceptualHash: String?) async throws -> [String] {
        let lambda = AWSLambda.default()
        
        let payload: [String: Any] = [
            "action": "analyzeContent",
            "s3Key": s3Key,
            "sha256Hash": sha256Hash,
            "perceptualHash": perceptualHash ?? "",
            "bucket": s3Bucket
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        
        let request = AWSLambdaInvocationRequest()!
        request.functionName = lambdaFunctionName
        request.invocationType = .requestResponse
        request.payload = jsonData
        
        let result = try await lambda.invoke(request)
        
        guard let responseData = result.payload as? Data else {
            return []
        }
        
        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData,
                                                           options: []) as? [String: Any],
              let tags = responseJSON["tags"] as? [String] else {
            Logger.error("Failed to parse Lambda response")
            return []
        }
        
        return tags
    }
}

// MARK: - AWSRegionType Extension

extension AWSRegionType {
    init?(string: String) {
        switch string.lowercased() {
        case "us-east-1": self = .USEast1
        case "us-east-2": self = .USEast2
        case "us-west-1": self = .USWest1
        case "us-west-2": self = .USWest2
        case "eu-west-1": self = .EUWest1
        case "eu-central-1": self = .EUCentral1
        case "ap-southeast-1": self = .APSoutheast1
        case "ap-northeast-1": self = .APNortheast1
        case "ap-southeast-2": self = .APSoutheast2
        case "sa-east-1": self = .SAEast1
        default: return nil
        }
    }
}

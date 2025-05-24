import Foundation
import AWSS3
import AWSCore
import AWSLambda
import AWSDynamoDB
import UIKit

// MARK: - FilterResult Enum

public enum ContentFilterError: Error {
    case configurationError(String)
    case processingError(String)
    case uploadError(String)
    case analysisError(String)
    case duplicateError(String)
}

@objc
public class ContentFilterService: NSObject {
    @objc
    public static let shared = ContentFilterService()
    
    private let s3Bucket: String
    private let lambdaFunctionName: String
    private let region: AWSRegionType
    
    private override init() {
        // Load configuration from Info.plist
        guard let bucket = Bundle.main.object(forInfoDictionaryKey: "AWSContentFilterBucket") as? String,
              let functionName = Bundle.main.object(forInfoDictionaryKey: "AWSContentFilterFunction") as? String else {
            fatalError("Missing AWS configuration in Info.plist")
        }
        
        self.s3Bucket = bucket
        self.lambdaFunctionName = functionName
        self.region = .USEast1  // Hardcode to US East 1 since that's what we use
        
        super.init()
        
        do {
            try configureAWS()
        } catch {
            owsFailDebug("Failed to configure AWS: \(error)")
        }
    }
    
    private func configureAWS() throws {
        guard let poolID = Bundle.main.object(forInfoDictionaryKey: "AWSContentFilterPoolID") as? String else {
            throw ContentFilterError.configurationError("Missing AWSContentFilterPoolID in Info.plist")
        }
        
        let credentialsProvider = AWSCognitoCredentialsProvider(regionType: region, identityPoolId: poolID)
        let configuration = AWSServiceConfiguration(region: region, credentialsProvider: credentialsProvider)
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        AWSS3.register(with: configuration!, forKey: "S3")
        AWSLambda.register(with: configuration!, forKey: "Lambda")
        AWSDynamoDB.register(with: configuration!, forKey: "DynamoDB")
        
        // Enable AWS SDK logging
        AWSDDLog.sharedInstance.logLevel = .info
    }
    
    // MARK: - Image Processing
    
    private func processImage(_ imageData: Data) -> (sha256Hash: String, perceptualHash: String?)? {
        // Create UIImage from data
        guard let image = UIImage(data: imageData) else {
            Logger.error("ContentFilter: Failed to create UIImage from data")
            return nil
        }
        
        // Compute hashes using ImageHashing
        return ImageHashing.shared.computeHashes(for: image)
    }
    
    // MARK: - S3 Operations
    
    private func deleteS3Object(key: String, completion: @escaping (Error?) -> Void) {
        let s3 = AWSS3.default()
        let deleteRequest = AWSS3DeleteObjectRequest()
        deleteRequest?.bucket = s3Bucket
        deleteRequest?.key = key
        
        s3.deleteObject(deleteRequest!).continueWith { task in
            if let error = task.error {
                Logger.error("ContentFilter: Failed to delete S3 object: \(error)")
                completion(error)
            } else {
                Logger.info("ContentFilter: Successfully deleted S3 object: \(key)")
                completion(nil)
            }
            return nil
        }
    }
    
    // MARK: - DynamoDB Duplicate Detection
    
    private func checkGlobalDuplicate(sha256Hash: String, completion: @escaping (Bool) -> Void) {
        let dynamoDB = AWSDynamoDB.default()
        let input = AWSDynamoDBGetItemInput()
        input?.tableName = "GlobalImageHashes" // Table name must match your AWS setup
        input?.key = ["sha256Hash": AWSDynamoDBAttributeValue(s: sha256Hash)]
        
        dynamoDB.getItem(input!).continueWith { task in
            if let error = task.error {
                Logger.error("ContentFilter: DynamoDB getItem failed: \(error)")
                completion(false)
                return nil
            }
            if let result = task.result, let item = result.item, !item.isEmpty {
                completion(true) // Duplicate found
            } else {
                completion(false) // Not a duplicate
            }
            return nil
        }
    }
    
    private func markGlobalDuplicate(sha256Hash: String) {
        let dynamoDB = AWSDynamoDB.default()
        let input = AWSDynamoDBPutItemInput()
        input?.tableName = "GlobalImageHashes"
        input?.item = ["sha256Hash": AWSDynamoDBAttributeValue(s: sha256Hash)]
        dynamoDB.putItem(input!)
    }
    
    // MARK: - Public Methods
    
    public func scanAndUpload(imageData: Data, fileName: String) async -> FilterResult {
        return await withCheckedContinuation { continuation in
            scanAndUpload(imageData: imageData, fileName: fileName) { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    public func scanAndUpload(imageData: Data, fileName: String, completion: @escaping (FilterResult) -> Void) {
        // 1. Process image and compute hashes
        guard let (sha256Hash, perceptualHash) = processImage(imageData) else {
            Logger.error("ContentFilter: Failed to process image")
            completion(.error(ContentFilterError.processingError("Failed to process image")))
            return
        }
        
        // 2. Check for global duplicate using DynamoDB
        checkGlobalDuplicate(sha256Hash: sha256Hash) { [weak self] isGlobalDuplicate in
            if isGlobalDuplicate {
                completion(.blocked(reason: "Global duplicate image detected", tags: []))
                return
            }
            // 3. Check for local duplicate using DuplicateFilterService
            guard let image = UIImage(data: imageData) else {
                Logger.error("ContentFilter: Failed to create UIImage from data")
                completion(.error(ContentFilterError.processingError("Failed to create UIImage")))
                return
            }
            DuplicateFilterService.shared.checkDuplicate(image: image) { result in
                switch result {
                case .success(let isDuplicate):
                    if isDuplicate {
                        completion(.blocked(reason: "Duplicate image detected", tags: []))
                        return
                    }
                    // 4. Upload to S3 bucket
                    let s3Key = "images/\(sha256Hash).jpg"
                    let expression = AWSS3TransferUtilityUploadExpression()
                    let transferUtility = AWSS3TransferUtility.default()
                    transferUtility.uploadData(imageData,
                                             bucket: self?.s3Bucket ?? "",
                                             key: s3Key,
                                             contentType: "image/jpeg",
                                             expression: expression) { task, error in
                        if let error = error {
                            Logger.error("ContentFilter: S3 upload failed: \(error)")
                            completion(.error(ContentFilterError.uploadError(error.localizedDescription)))
                            return
                        }
                        // 5. Call Lambda function for content analysis
                        self?.analyzeContent(s3Key: s3Key, sha256Hash: sha256Hash, perceptualHash: perceptualHash) { result in
                            switch result {
                            case .allowed(let tags, let s3URL):
                                // Mark as globally uploaded
                                self?.markGlobalDuplicate(sha256Hash: sha256Hash)
                                completion(.allowed)
                            case .blocked(let reason, let tags):
                                // Delete the uploaded image since it's blocked
                                self?.deleteS3Object(key: s3Key) { _ in }
                                completion(.blocked(reason: reason, tags: tags))
                            case .error(let error):
                                // Delete the uploaded image since there was an error
                                self?.deleteS3Object(key: s3Key) { _ in }
                                completion(.error(error))
                            }
                        }
                    }
                case .failure(let error):
                    Logger.error("ContentFilter: Duplicate check failed: \(error)")
                    completion(.error(ContentFilterError.duplicateError(error.localizedDescription)))
                }
            }
        }
    }
    
    // MARK: - AWS Lambda Integration
    
    private func analyzeContent(s3Key: String, sha256Hash: String, perceptualHash: String?, completion: @escaping (FilterResult) -> Void) {
        let lambda = AWSLambda.default()
        
        // Prepare payload
        let payload: [String: Any] = [
            "s3Key": s3Key,
            "sha256Hash": sha256Hash,
            "perceptualHash": perceptualHash as Any,
            "bucket": s3Bucket
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            Logger.error("ContentFilter: Failed to serialize Lambda payload")
            completion(.error(ContentFilterError.analysisError("Failed to serialize payload")))
            return
        }
        
        guard let request = AWSLambdaInvokerInvocationRequest() else {
            Logger.error("ContentFilter: Failed to create Lambda request")
            completion(.error(ContentFilterError.analysisError("Failed to create Lambda request")))
            return
        }
        request.functionName = lambdaFunctionName
        request.invocationType = .requestResponse
        request.payload = jsonData
        
        // Add retry logic for tag polling
        var retryCount = 0
        let maxRetries = 3
        let retryDelay: TimeInterval = 1.0
        
        func invokeLambda() {
            lambda.invoke(request).continueWith { task in
                if let error = task.error {
                    Logger.error("ContentFilter: Lambda invocation failed: \(error)")
                    completion(.error(ContentFilterError.analysisError(error.localizedDescription)))
                    return nil
                }
                
                guard let result = task.result,
                      let responseData = result.payload as? Data,
                      let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    Logger.error("ContentFilter: Failed to parse Lambda response")
                    completion(.error(ContentFilterError.analysisError("Failed to parse response")))
                    return nil
                }
                
                // Parse response
                let tags = responseJSON["tags"] as? [String] ?? []
                let isDuplicate = responseJSON["isDuplicate"] as? Bool ?? false
                let isBlocked = responseJSON["isBlocked"] as? Bool ?? false
                let reason = responseJSON["reason"] as? String ?? "Unknown reason"
                
                // If no tags and we haven't exceeded retries, try again
                if tags.isEmpty && retryCount < maxRetries {
                    retryCount += 1
                    Logger.info("ContentFilter: No tags received, retrying (\(retryCount)/\(maxRetries))")
                    DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) {
                        invokeLambda()
                    }
                    return nil
                }
                
                if isDuplicate {
                    completion(.blocked(reason: "Duplicate image detected", tags: tags))
                } else if isBlocked {
                    completion(.blocked(reason: reason, tags: tags))
                } else {
                    // Create S3 URL for allowed images
                    let s3URL = URL(string: "https://\(self.s3Bucket).s3.amazonaws.com/\(s3Key)")!
                    completion(.allowed)
                }
                
                return nil
            }
        }
        
        // Start the first invocation
        invokeLambda()
    }
} 
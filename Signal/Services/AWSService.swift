import Foundation
import AWSS3
import AWSDynamoDB
import UIKit
import SignalServiceKit

enum AWSServiceError: Error {
    case invalidImage
    case uploadFailed(Error)
    case duplicateImage
    case networkError(String)
    case serverError(String)
    case invalidResponse
    case cancelled
    case timeout
    case unknown(String)
    
    var localizedDescription: String {
        switch self {
        case .invalidImage:
            return "Invalid or corrupted image data"
        case .uploadFailed(let error):
            return "Upload failed: \(error)"
        case .duplicateImage:
            return "Image already exists in the system"
        case .networkError(let message):
            return "Network error: \(message)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        case .cancelled:
            return "Upload was cancelled"
        case .timeout:
            return "Request timed out"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}

class AWSService {
    static let shared = AWSService()
    private let config = AWSConfig.shared
    private var activeUploads: [String: AWSS3TransferUtilityTask] = [:]
    private let uploadQueue = DispatchQueue(label: "com.signal.aws.upload", qos: .userInitiated)
    private let cleanupQueue = DispatchQueue(label: "com.signal.aws.cleanup", qos: .utility)
    
    private init() {
        setupCleanupTimer()
    }
    
    // MARK: - Image Upload
    
    func uploadImage(_ image: UIImage, progressHandler: ((Double) -> Void)? = nil, completion: @escaping (Result<String, Error>) -> Void) -> String? {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(.failure(AWSServiceError.invalidImage))
            return nil
        }
        
        let uploadId = UUID().uuidString
        let fileName = "\(uploadId).jpg"
        let key = "\(config.s3ImagesPath)/\(fileName)"
        
        let expression = AWSS3TransferUtilityUploadExpression()
        expression.progressBlock = { task, progress in
            progressHandler?(progress.fractionCompleted)
        }
        
        // Add retry configuration
        expression.retryBlock = { [weak self] task, error in
            guard let self = self else { return false }
            return self.shouldRetry(error: error as NSError)
        }
        
        let transferUtility = AWSS3TransferUtility.default()
        
        uploadQueue.async { [weak self] in
            guard let self = self else { return }
            
            transferUtility.uploadData(
                imageData,
                bucket: self.config.s3BucketName,
                key: key,
                contentType: "image/jpeg",
                expression: expression
            ) { [weak self] task, error in
                guard let self = self else { return }
                
                self.uploadQueue.async {
                    self.activeUploads.removeValue(forKey: uploadId)
                    
                    if let error = error as NSError? {
                        if error.domain == AWSS3TransferUtilityErrorDomain {
                            switch error.code {
                            case AWSS3TransferUtilityErrorType.cancelled.rawValue:
                                completion(.failure(AWSServiceError.uploadFailed(error)))
                            case AWSS3TransferUtilityErrorType.networkError.rawValue:
                                completion(.failure(AWSServiceError.networkError(error.localizedDescription)))
                            case AWSS3TransferUtilityErrorType.serverError.rawValue:
                                completion(.failure(AWSServiceError.serverError(error.localizedDescription)))
                            default:
                                completion(.failure(AWSServiceError.unknown(error.localizedDescription)))
                            }
                        } else {
                            completion(.failure(AWSServiceError.unknown(error.localizedDescription)))
                        }
                        return
                    }
                    
                    let imageURL = "\(self.config.s3BaseURL)/\(key)"
                    completion(.success(imageURL))
                }
            }
        }
        
        return uploadId
    }
    
    func cancelUpload(uploadId: String) {
        uploadQueue.async { [weak self] in
            guard let self = self else { return }
            if let task = self.activeUploads[uploadId] {
                task.cancel()
                self.activeUploads.removeValue(forKey: uploadId)
            }
        }
    }
    
    // MARK: - DynamoDB Operations
    
    func saveImageSignature(hash: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let dynamoDB = AWSDynamoDB.default()
        
        let item: [String: AWSDynamoDBAttributeValue] = [
            "ContentHash": .init(s: hash),
            "Timestamp": .init(s: ISO8601DateFormatter().string(from: Date())),
            "TTL": .init(n: String(Date().timeIntervalSince1970 + 30 * 24 * 60 * 60)) // 30 days TTL
        ]
        
        let input = AWSDynamoDBPutItemInput()
        input.tableName = config.dynamoDbTableName
        input.item = item
        
        // Add retry logic with exponential backoff
        var retryCount = 0
        let maxRetries = config.maxRetryCount
        
        func attemptPutItem() {
            dynamoDB.putItem(input) { [weak self] response, error in
                guard let self = self else { return }
                
                if let error = error as NSError? {
                    if retryCount < maxRetries && self.shouldRetry(error: error) {
                        retryCount += 1
                        let delay = self.calculateRetryDelay(retryCount: retryCount)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            attemptPutItem()
                        }
                    } else {
                        completion(.failure(AWSServiceError.serverError(error.localizedDescription)))
                    }
                    return
                }
                completion(.success(()))
            }
        }
        
        attemptPutItem()
    }
    
    func getImageSignature(hash: String, completion: @escaping (Result<[String: AWSDynamoDBAttributeValue]?, Error>) -> Void) {
        let dynamoDB = AWSDynamoDB.default()
        
        let key: [String: AWSDynamoDBAttributeValue] = [
            "ContentHash": .init(s: hash)
        ]
        
        let input = AWSDynamoDBGetItemInput()
        input.tableName = config.dynamoDbTableName
        input.key = key
        
        // Add retry logic with exponential backoff
        var retryCount = 0
        let maxRetries = config.maxRetryCount
        
        func attemptGetItem() {
            dynamoDB.getItem(input) { [weak self] response, error in
                guard let self = self else { return }
                
                if let error = error as NSError? {
                    if retryCount < maxRetries && self.shouldRetry(error: error) {
                        retryCount += 1
                        let delay = self.calculateRetryDelay(retryCount: retryCount)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            attemptGetItem()
                        }
                    } else {
                        completion(.failure(AWSServiceError.serverError(error.localizedDescription)))
                    }
                    return
                }
                completion(.success(response?.item))
            }
        }
        
        attemptGetItem()
    }
    
    // MARK: - API Gateway Operations
    
    func getImageTags(imageURL: String, completion: @escaping (Result<[String], Error>) -> Void) {
        guard let url = URL(string: config.getTagApiGatewayEndpoint) else {
            completion(.failure(AWSServiceError.invalidResponse))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.getTagApiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = config.requestTimeoutInterval
        
        let body: [String: Any] = ["imageUrl": imageURL]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        // Add retry logic with exponential backoff
        var retryCount = 0
        let maxRetries = config.maxRetryCount
        
        func attemptRequest() {
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                
                if let error = error as NSError? {
                    if retryCount < maxRetries && self.shouldRetry(error: error) {
                        retryCount += 1
                        let delay = self.calculateRetryDelay(retryCount: retryCount)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            attemptRequest()
                        }
                    } else {
                        completion(.failure(AWSServiceError.networkError(error.localizedDescription)))
                    }
                    return
                }
                
                guard let data = data else {
                    completion(.failure(AWSServiceError.invalidResponse))
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tags = json["tags"] as? [String] {
                        completion(.success(tags))
                    } else {
                        completion(.failure(AWSServiceError.invalidResponse))
                    }
                } catch {
                    completion(.failure(AWSServiceError.unknown(error.localizedDescription)))
                }
            }
            
            task.resume()
        }
        
        attemptRequest()
    }
    
    // MARK: - Helper Methods
    
    private func shouldRetry(error: NSError) -> Bool {
        // Check if error is retryable
        let retryableErrorCodes: Set<Int> = [
            AWSS3TransferUtilityErrorType.networkError.rawValue,
            AWSS3TransferUtilityErrorType.serverError.rawValue
        ]
        
        return retryableErrorCodes.contains(error.code)
    }
    
    private func calculateRetryDelay(retryCount: Int) -> TimeInterval {
        // Exponential backoff with jitter
        let baseDelay = config.initialRetryDelay
        let maxDelay = config.maxRetryDelay
        let exponentialDelay = baseDelay * pow(2.0, Double(retryCount - 1))
        let jitter = Double.random(in: 0...0.1) * exponentialDelay
        return min(exponentialDelay + jitter, maxDelay)
    }
    
    private func setupCleanupTimer() {
        // Run cleanup every hour
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.cleanupStaleUploads()
        }
    }
    
    private func cleanupStaleUploads() {
        cleanupQueue.async { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            for (uploadId, task) in self.activeUploads {
                if let startTime = task.startTime,
                   now.timeIntervalSince(startTime) > 300 { // 5 minutes timeout
                    task.cancel()
                    self.activeUploads.removeValue(forKey: uploadId)
                }
            }
        }
    }
} 
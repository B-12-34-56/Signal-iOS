import Foundation
import AWSCore
import AWSAPIGateway
import AWSS3

class AWSServiceManager {
    static let shared = AWSServiceManager()
    
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 2.0
    private let bucketName = "signal-images-bucket"
    private let region = AWSRegionType.USEast1
    
    private init() {
        setupAWS()
    }
    
    private func setupAWS() {
        // Configure AWS credentials
        let credentialsProvider = AWSCognitoCredentialsProvider(
            regionType: region,
            identityPoolId: "us-east-1:12345678-1234-1234-1234-123456789012"
        )
        
        let configuration = AWSServiceConfiguration(
            region: region,
            credentialsProvider: credentialsProvider
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
    
    func uploadImageData(_ imageData: Data, key: String, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        let transferUtility = AWSS3TransferUtility.default()
        
        let expression = AWSS3TransferUtilityUploadExpression()
        expression.progressBlock = { task, progress in
            progressHandler(progress.fractionCompleted)
        }
        
        // Add retry logic
        func attemptUpload(retryCount: Int) {
            transferUtility.uploadData(
                imageData,
                bucket: bucketName,
                key: key,
                contentType: "image/jpeg",
                expression: expression
            ) { task, error in
                if let error = error {
                    if retryCount < self.maxRetries {
                        // Retry after delay
                        DispatchQueue.global().asyncAfter(deadline: .now() + self.retryDelay) {
                            attemptUpload(retryCount: retryCount + 1)
                        }
                    } else {
                        completion(.failure(error))
                    }
                    return
                }
                
                // Get the URL of the uploaded object
                let s3 = AWSS3.default()
                let request = AWSS3GetObjectRequest()
                request?.bucket = self.bucketName
                request?.key = key
                
                s3.getObject(request!) { response, error in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }
                    
                    if let url = response?.body as? Data {
                        completion(.success(key))
                    } else {
                        completion(.failure(NSError(domain: "AWSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get uploaded object URL"])))
                    }
                }
            }
        }
        
        attemptUpload(retryCount: 0)
    }
    
    func deleteImage(key: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let s3 = AWSS3.default()
        
        let deleteRequest = AWSS3DeleteObjectRequest()
        deleteRequest?.bucket = bucketName
        deleteRequest?.key = key
        
        func attemptDelete(retryCount: Int) {
            s3.deleteObject(deleteRequest!) { response, error in
                if let error = error {
                    if retryCount < self.maxRetries {
                        // Retry after delay
                        DispatchQueue.global().asyncAfter(deadline: .now() + self.retryDelay) {
                            attemptDelete(retryCount: retryCount + 1)
                        }
                    } else {
                        completion(.failure(error))
                    }
                    return
                }
                
                completion(.success(()))
            }
        }
        
        attemptDelete(retryCount: 0)
    }
    
    // MARK: - API Gateway Operations
    
    func callAPI(path: String, method: String, parameters: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        let apiClient = AWSAPIGatewayClient.default()
        
        let request = AWSAPIGatewayRequest()
        request.httpMethod = method
        request.path = path
        request.parameters = parameters
        
        func attemptCall(retryCount: Int) {
            apiClient.invoke(request) { response, error in
                if let error = error {
                    if retryCount < self.maxRetries {
                        // Retry after delay
                        DispatchQueue.global().asyncAfter(deadline: .now() + self.retryDelay) {
                            attemptCall(retryCount: retryCount + 1)
                        }
                    } else {
                        completion(.failure(error))
                    }
                    return
                }
                
                if let responseBody = response?.responseBody {
                    completion(.success(responseBody))
                } else {
                    completion(.failure(NSError(domain: "AWSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty response from API"])))
                }
            }
        }
        
        attemptCall(retryCount: 0)
    }
} 
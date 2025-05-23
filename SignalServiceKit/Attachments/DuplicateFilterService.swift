import Foundation
import AWSLambda
import AWSCore
import UIKit

public enum DuplicateFilterError: Error {
    case configurationError(String)
    case processingError(String)
    case networkError(String)
    case responseError(String)
}

@objc
public class DuplicateFilterService: NSObject {
    @objc
    public static let shared = DuplicateFilterService()
    
    private let lambdaFunctionName: String
    private let region: AWSRegionType
    private let threshold: Int
    
    private override init() {
        // Load configuration from Info.plist
        guard let functionName = Bundle.main.object(forInfoDictionaryKey: "AWSContentFilterFunction") as? String,
              let thresholdValue = Bundle.main.object(forInfoDictionaryKey: "DuplicateThreshold") as? Int else {
            fatalError("Missing AWS configuration in Info.plist")
        }
        
        self.lambdaFunctionName = functionName
        self.region = .USEast1  // Hardcode to US East 1 since that's what we use
        self.threshold = thresholdValue
        
        super.init()
    }
    
    // MARK: - Public Methods
    
    @objc
    public func checkDuplicate(image: UIImage, completion: @escaping (Result<Bool, Error>) -> Void) {
        // 1. Compute hashes
        guard let (sha256Hash, perceptualHash) = ImageHashing.shared.computeHashes(for: image) else {
            completion(.failure(DuplicateFilterError.processingError("Failed to compute image hashes")))
            return
        }
        
        // 2. Prepare Lambda payload
        let payload: [String: Any] = [
            "sha256Hash": sha256Hash,
            "perceptualHash": perceptualHash as Any
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(DuplicateFilterError.processingError("Failed to serialize payload")))
            return
        }
        
        // 3. Call Lambda function
        let lambda = AWSLambda.default()
        let request = AWSLambdaInvokerInvocationRequest()
        request.functionName = lambdaFunctionName
        request.invocationType = .requestResponse
        request.payload = jsonData
        
        lambda.invoke(request).continueWith { task in
            if let error = task.error {
                Logger.error("DuplicateFilter: Lambda invocation failed: \(error)")
                completion(.failure(DuplicateFilterError.networkError(error.localizedDescription)))
                return nil
            }
            
            guard let result = task.result,
                  let responseData = result.payload as? Data,
                  let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                Logger.error("DuplicateFilter: Failed to parse Lambda response")
                completion(.failure(DuplicateFilterError.responseError("Failed to parse response")))
                return nil
            }
            
            // Parse response
            let duplicateCount = responseJSON["duplicateCount"] as? Int ?? 0
            let isDuplicate = duplicateCount > self.threshold
            
            if isDuplicate {
                Logger.info("DuplicateFilter: Image is duplicate (count: \(duplicateCount))")
            }
            
            completion(.success(isDuplicate))
            return nil
        }
    }
    
    // MARK: - Async/Await Support
    
    @objc
    public func checkDuplicate(image: UIImage) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            checkDuplicate(image: image) { result in
                switch result {
                case .success(let isDuplicate):
                    continuation.resume(returning: isDuplicate)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
} 
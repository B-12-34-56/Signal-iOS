import Foundation
import AWSLambda
import AWSCore
import AWSCognitoIdentityProvider
import UIKit

public final class DuplicateFilterService {
    public enum FilterError: Error {
        case configuration(String)
        case lambda(Error)
        case badResponse
        case networkUnavailable
    }
    
    // MARK: - Singleton
    public static let shared = DuplicateFilterService()
    
    // MARK: - Properties
    private let lambda: AWSLambda
    private let functionName: String
    private let threshold: Int
    
    // MARK: - Init
    private init() {
        guard
            let fn = Bundle.main.infoDictionary?["ContentFilterLambdaName"] as? String,
            !fn.isEmpty,
            let th = Bundle.main.infoDictionary?["DuplicateThreshold"] as? Int
        else {
            fatalError("Missing ContentFilterLambdaName or DuplicateThreshold in Info.plist")
        }
        
        self.lambda = .default()
        self.functionName = fn
        self.threshold = th
    }
    
    // MARK: - Public API
    
    /// Check if an image is a duplicate
    /// - Parameter image: The image to check
    /// - Returns: Result indicating if the image should be blocked
    public func checkDuplicate(image: UIImage, completion: @escaping (Result<Bool, Error>) -> Void) {
        Task {
            do {
                let hashes = try await ImageHashing.hashes(for: image)
                let pHashInt = UInt64(hashes.1, radix: 16) ?? 0
                let isDuplicate = try await checkDuplicateAsync((sha256: hashes.0, pHash: pHashInt))
                completion(.success(isDuplicate))
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    /// Async version for checking duplicates
    public func checkDuplicateAsync(_ hashes: (sha256: String, pHash: UInt64)) async throws -> Bool {
        // Get user ID - use a default if not available
        let userId = getUserId()
        
        // Prepare request
        let requestPayload = DuplicateCheckRequest(
            sha256: hashes.sha256,
            pHash: String(hashes.pHash),
            userId: userId
        )
        
        // Try to call Lambda with retry logic
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let response = try await invokeLambda(with: requestPayload)
                
                // Threshold sanity check
                if response.duplicateCount >= threshold {
                    Logger.info("Duplicate check: count=\(response.duplicateCount) >= threshold=\(threshold), blocking")
                    return true
                }
                
                // Trust the Lambda response but verify
                if response.allow == false && response.duplicateCount < threshold {
                    Logger.warn("Lambda returned allow=false but count < threshold, overriding to block")
                    return true
                }
                
                return !response.allow
            } catch {
                lastError = error
                Logger.warn("Duplicate check attempt \(attempt) failed: \(error)")
                
                // Wait before retry
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
            }
        }
        
        // Offline fallback: allow the send
        Logger.warn("All duplicate check attempts failed, allowing send due to offline fallback")
        return false
    }
    
    // MARK: - Private Helpers
    
    private func getUserId() -> String {
        // Try to get user ID from various sources
        // 1. Try from UserDefaults or keychain
        if let storedUserId = UserDefaults.standard.string(forKey: "userIdentifier"), !storedUserId.isEmpty {
            return storedUserId
        }
        
        // 2. Generate a UUID and store it
        let newUserId = UUID().uuidString
        UserDefaults.standard.set(newUserId, forKey: "userIdentifier")
        return newUserId
    }
    
    private func invokeLambda(with payload: DuplicateCheckRequest) async throws -> DuplicateCheckResponse {
        let request = AWSLambdaInvocationRequest()!
        request.functionName = functionName
        request.payload = try JSONEncoder().encode(payload)
        
        let response = try await lambda.invoke(request)
        
        guard let data = response.payload as? Data else {
            throw FilterError.badResponse
        }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                throw FilterError.badResponse
            }
            
            // Parse response
            guard
                let duplicateCount = json["duplicateCount"] as? Int,
                let allow = json["allow"] as? Bool
            else {
                throw FilterError.badResponse
            }
            
            return DuplicateCheckResponse(
                duplicateCount: duplicateCount,
                allow: allow
            )
        } catch {
            throw FilterError.lambda(error)
        }
    }
}

// MARK: - Request/Response Models

private struct DuplicateCheckRequest: Codable {
    let sha256: String
    let pHash: String
    let userId: String
}

private struct DuplicateCheckResponse {
    let duplicateCount: Int
    let allow: Bool
}

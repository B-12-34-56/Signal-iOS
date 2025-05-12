import Foundation
import AWSDynamoDB

public class GlobalSignatureService {
    public static let shared = GlobalSignatureService()
    
    private let maxCacheSize = 1000
    private var cache: [String: (exists: Bool, timestamp: Date)] = [:]
    private let queue = DispatchQueue(label: "com.signal.globalsignatureservice")
    
    private init() {}
    
    public func checkHashExists(_ hash: Data) async throws -> Bool {
        let hexString = hash.map { String(format: "%02x", $0) }.joined()
        
        // Check cache first
        if let cached = queue.sync(execute: { cache[hexString] }) {
            return cached.exists
        }
        
        // Check DynamoDB
        let dynamoDB = AWSDynamoDB.default()
        let getItemInput = AWSDynamoDBGetItemInput()
        getItemInput.tableName = AWSConfig.getDynamoDBTableName()
        getItemInput.key = ["Hash": AWSDynamoDBAttributeValue(s: hexString)]
        
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                dynamoDB.getItem(getItemInput) { result, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
            
            let exists = result.item != nil
            
            // Update cache
            queue.sync {
                // Remove oldest entry if cache is full
                if cache.count >= maxCacheSize {
                    let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
                    if let oldest = oldest {
                        cache.removeValue(forKey: oldest.key)
                    }
                }
                cache[hexString] = (exists, Date())
            }
            
            return exists
        } catch let error as NSError {
            if error.domain == AWSDynamoDBErrorDomain && error.code == AWSDynamoDBErrorType.throttling.rawValue {
                // Retry with exponential backoff
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                return try await checkHashExists(hash)
            }
            throw error
        }
    }
    
    public func storeHash(_ hash: Data) async throws {
        let hexString = hash.map { String(format: "%02x", $0) }.joined()
        
        let dynamoDB = AWSDynamoDB.default()
        let putItemInput = AWSDynamoDBPutItemInput()
        putItemInput.tableName = AWSConfig.getDynamoDBTableName()
        putItemInput.item = [
            "Hash": AWSDynamoDBAttributeValue(s: hexString),
            "Timestamp": AWSDynamoDBAttributeValue(n: String(Date().timeIntervalSince1970))
        ]
        
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                dynamoDB.putItem(putItemInput) { result, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
            
            // Update cache
            queue.sync {
                cache[hexString] = (true, Date())
            }
        } catch let error as NSError {
            if error.domain == AWSDynamoDBErrorDomain && error.code == AWSDynamoDBErrorType.throttling.rawValue {
                // Retry with exponential backoff
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                try await storeHash(hash)
            }
            throw error
        }
    }
} 
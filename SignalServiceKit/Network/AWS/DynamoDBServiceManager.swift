import Foundation
import AWSDynamoDB

final class DynamoDBServiceManager {
    static let shared = DynamoDBServiceManager()
    private init() {}

    private let table = Bundle.main.object(forInfoDictionaryKey: "DYNAMODB_TABLE_NAME") as? String ?? "ImageHashIndex"

    // -------- Duplicate check --------
    func checkForDuplicate(signature: String, perceptualHash: String) async throws -> Bool {
        // Check SHA-256 signature
        let queryInput = AWSDynamoDBQueryInput()
        queryInput.tableName = table
        queryInput.keyConditionExpression = "#k = :sig"
        queryInput.expressionAttributeNames = ["#k": "signature"]
        queryInput.expressionAttributeValues = [":sig": .init(s: signature)]
        
        return try await withCheckedThrowingContinuation { continuation in
            AWSDynamoDB.default().query(queryInput) { output, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let items = output?.items, !items.isEmpty {
                    continuation.resume(returning: true)
                    return
                }
                
                // If no exact match, check perceptual hash
                let scanInput = AWSDynamoDBScanInput()
                scanInput.tableName = self.table
                scanInput.filterExpression = "perceptual_hash = :hash"
                scanInput.expressionAttributeValues = [":hash": .init(s: perceptualHash)]
                
                AWSDynamoDB.default().scan(scanInput) { output, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    continuation.resume(returning: output?.items?.isEmpty == false)
                }
            }
        }
    }

    // -------- Store new record --------
    func storeSignature(signature: String,
                       perceptualHash: String,
                       imageKey: String,
                       completion: @escaping (Result<Void, Error>) -> Void) {

        let put = AWSDynamoDBPutItemInput()!
        put.tableName = table
        put.item = [
            "signature"       : .init(s: signature),
            "perceptualHash"  : .init(s: perceptualHash),
            "s3Key"           : .init(s: imageKey),
            "uploadedAt"      : .init(s: ISO8601DateFormatter().string(from: Date()))
        ]
        AWSDynamoDB.default().putItem(put) { _, err in
            DispatchQueue.main.async {
                err == nil ? completion(.success(())) : completion(.failure(err!))
            }
        }
    }
} 
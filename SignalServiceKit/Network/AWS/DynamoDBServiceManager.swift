import Foundation
import AWSDynamoDB

final class DynamoDBServiceManager {
    static let shared = DynamoDBServiceManager()
    private init() {}

    private let table = Bundle.main.object(forInfoDictionaryKey: "DYNAMODB_TABLE_NAME") as? String ?? "ImageHashIndex"

    // -------- Duplicate check --------
    func checkForDuplicate(signature: String,
                          perceptualHash: String,
                          completion: @escaping (Result<Bool, Error>) -> Void) {

        // PK query – exact SHA-256 match
        let keyCond = AWSDynamoDBQueryExpression()
        keyCond.keyConditionExpression = "#k = :sig"
        keyCond.expressionAttributeNames  = ["#k" : "signature"]
        keyCond.expressionAttributeValues = [":sig": signature]
        keyCond.tableName = table

        AWSDynamoDB.default().query(keyCond) { pkResp, pkErr in
            if let e = pkErr { return completion(.failure(e)) }
            guard pkResp?.count == 0 else { return completion(.success(true)) }

            // Fallback scan by perceptualHash
            let scan = AWSDynamoDBScanExpression()
            scan.filterExpression = "#ph = :p"
            scan.expressionAttributeNames  = ["#ph": "perceptualHash"]
            scan.expressionAttributeValues = [":p": perceptualHash]
            scan.tableName = self.table

            AWSDynamoDB.default().scan(scan) { scResp, scErr in
                if let e = scErr { completion(.failure(e)) }
                else             { completion(.success( (scResp?.count ?? 0) > 0 )) }
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
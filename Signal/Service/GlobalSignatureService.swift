import Foundation
<<<<<<< HEAD

final class GlobalSignatureService {
    static let shared = GlobalSignatureService()
    private let db = DynamoDBServiceManager.shared

    func getS3Key(for hash: String) async -> String? {
        await db.getS3Key(for: hash)
    }

    func store(hash: String, s3Key: String) async -> Bool {
        await db.store(hash: hash, s3Key: s3Key)
=======
import AWSDynamoDB

class GlobalSignatureService {
    static let shared = GlobalSignatureService()
    private let dynamoDB = AWSDynamoDB.default()
    private let tableName = "YourDynamoDBTableName" // Replace with your table name

    func saveImageSignature(hash: String, s3Key: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let item: [String: AWSDynamoDBAttributeValue] = [
            "ContentHash": .init(s: hash),
            "S3Key": .init(s: s3Key)
        ]
        let putReq = AWSDynamoDBPutItemInput()!
        putReq.tableName = tableName
        putReq.item = item
        putReq.conditionExpression = "attribute_not_exists(ContentHash)"

        dynamoDB.putItem(putReq).continueWith { task in
            if let error = task.error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
            return nil
        }
    }

    func getImageSignature(hash: String, completion: @escaping (Result<[String: AWSDynamoDBAttributeValue]?, Error>) -> Void) {
        let key: [String: AWSDynamoDBAttributeValue] = ["ContentHash": .init(s: hash)]
        let getReq = AWSDynamoDBGetItemInput()!
        getReq.tableName = tableName
        getReq.key = key

        dynamoDB.getItem(getReq).continueWith { task in
            if let error = task.error {
                completion(.failure(error))
            } else {
                completion(.success(task.result?.item))
            }
            return nil
        }
>>>>>>> origin/Ibrahim
    }
} 
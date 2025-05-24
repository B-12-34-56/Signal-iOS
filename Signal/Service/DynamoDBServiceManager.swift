import Foundation
import AWSDynamoDB
import AWSCore

private func attrS(_ value: String) -> AWSDynamoDBAttributeValue {
    let v = AWSDynamoDBAttributeValue()
    v?.s = value
    return v!
}

private func attrN(_ value: String) -> AWSDynamoDBAttributeValue {
    let v = AWSDynamoDBAttributeValue()
    v?.n = value
    return v!
}

class DynamoDBServiceManager {
    static let shared = DynamoDBServiceManager()

    private let tableName = "signal-image-signatures"
    private let dynamoDB: AWSDynamoDB

    private init() {
        // We assume AWSServiceBoot.configure() has already run at app launch,
        // so AWSDynamoDB.default() will use the correct AWSServiceConfiguration.
        self.dynamoDB = AWSDynamoDB.default()
    }

    // MARK: - Exact-match Duplicate Check

    func storeImageSignature(_ signature: String,
                             imageKey: String,
                             completion: @escaping (Error?) -> Void)
    {
        guard let request = AWSDynamoDBPutItemInput() else {
            completion(NSError(domain: "DynamoDBServiceManager",
                               code: -1,
                               userInfo: [NSLocalizedDescriptionKey:
                                    "Failed to create PutItemInput"]))
            return
        }
        request.tableName = tableName
        request.item = [
            "signature":      attrS(signature),
            "image_key":      attrS(imageKey),
            "timestamp":      attrN(String(Date().timeIntervalSince1970))
        ]

        dynamoDB.putItem(request) { _, error in
            completion(error)
        }
    }

    // MARK: - Full Duplicate-check Workflow

    func checkForDuplicate(signature: String,
                           perceptualHash: String,
                           completion: @escaping (Result<Bool, Error>) -> Void)
    {
        // 1) Exact-match query
        guard let q = AWSDynamoDBQueryInput() else {
            completion(.failure(NSError(domain: "DynamoDBServiceManager",
                                        code: -1,
                                        userInfo: [NSLocalizedDescriptionKey:
                                            "Failed to create QueryInput"])))
            return
        }
        q.tableName               = tableName
        q.indexName               = "SignatureIndex"
        q.keyConditionExpression  = "signature = :sig"
        q.expressionAttributeValues = [
            ":sig": attrS(signature)
        ]

        dynamoDB.query(q) { response, error in
            if let error = error {
                return completion(.failure(error))
            }
            if let items = response?.items, !items.isEmpty {
                // exact match → duplicate
                return completion(.success(true))
            }
            // 2) Fallback to perceptual-hash scan
            self.scanForPerceptualMatch(perceptualHash, completion: completion)
        }
    }

    private func scanForPerceptualMatch(_ hash: String,
                                        completion: @escaping (Result<Bool, Error>) -> Void)
    {
        guard let s = AWSDynamoDBScanInput() else {
            completion(.failure(NSError(domain: "DynamoDBServiceManager",
                                        code: -1,
                                        userInfo: [NSLocalizedDescriptionKey:
                                            "Failed to create ScanInput"])))
            return
        }
        s.tableName                = tableName
        s.filterExpression         = "perceptual_hash = :hash"
        s.expressionAttributeValues = [
            ":hash": attrS(hash)
        ]

        dynamoDB.scan(s) { response, error in
            if let error = error {
                return completion(.failure(error))
            }
            if let items = response?.items {
                for item in items {
                    if let stored = item["perceptual_hash"]?.s {
                        if self.hammingDistance(hash, stored) < 10 {
                            return completion(.success(true))
                        }
                    }
                }
            }
            completion(.success(false))
        }
    }

    // MARK: - Alternate storeSignature API

    func storeSignature(signature: String,
                        perceptualHash: String,
                        imageKey: String,
                        completion: @escaping (Result<Void, Error>) -> Void)
    {
        guard let r = AWSDynamoDBPutItemInput() else {
            return completion(.failure(NSError(domain: "DynamoDBServiceManager",
                                               code: -1,
                                               userInfo: [NSLocalizedDescriptionKey:
                                                    "Failed to create PutItemInput"])))
        }
        r.tableName = tableName
        r.item = [
            "signature":        attrS(signature),
            "perceptual_hash":  attrS(perceptualHash),
            "image_key":        attrS(imageKey),
            "timestamp":        attrS(ISO8601DateFormatter()
                                            .string(from: Date()))
        ]

        dynamoDB.putItem(r) { _, error in
            if let e = error {
                return completion(.failure(e))
            }
            completion(.success(()))
        }
    }

    // MARK: - Cleanup

    func deleteImageSignature(_ signature: String,
                              completion: @escaping (Error?) -> Void)
    {
        guard let d = AWSDynamoDBDeleteItemInput() else {
            completion(NSError(domain: "DynamoDBServiceManager",
                               code: -1,
                               userInfo: [NSLocalizedDescriptionKey:
                                    "Failed to create DeleteItemInput"]))
            return
        }
        d.tableName = tableName
        d.key = ["signature": attrS(signature)]

        dynamoDB.deleteItem(d) { _, error in
            completion(error)
        }
    }

    // MARK: - Utility

    private func hammingDistance(_ a: String, _ b: String) -> Int {
        guard a.count == b.count else { return Int.max }
        return zip(a, b).filter { $0 != $1 }.count
    }
<<<<<<< HEAD

    // MARK: - S3 Key Lookup for Deduplication
    func getS3Key(for hash: String) async -> String? {
        let key: [String: AWSDynamoDBAttributeValue] = ["signature": attrS(hash)]
        guard let getReq = AWSDynamoDBGetItemInput() else { return nil }
        getReq.tableName = tableName
        getReq.key = key
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                dynamoDB.getItem(getReq) { response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: response)
                    }
                }
            }
            if let item = result?.item, let s3Key = item["image_key"]?.s {
                return s3Key
            }
        } catch {
            return nil
        }
        return nil
    }

    func store(hash: String, s3Key: String) async -> Bool {
        guard let putReq = AWSDynamoDBPutItemInput() else { return false }
        putReq.tableName = tableName
        putReq.item = [
            "signature": attrS(hash),
            "image_key": attrS(s3Key),
            "timestamp": attrN(String(Date().timeIntervalSince1970))
        ]
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                dynamoDB.putItem(putReq) { _, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }
=======
>>>>>>> origin/Ibrahim
}

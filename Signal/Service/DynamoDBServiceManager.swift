import Foundation
import AWSDynamoDB
import AWSCore

class DynamoDBServiceManager {
    static let shared = DynamoDBServiceManager()
    
    private let tableName = "signal-image-signatures"
    private let dynamoDB = AWSDynamoDB.default()
    private let region = AWSRegionType.USEast1
    
    private init() {
        setupDynamoDB()
    }
    
    private func setupDynamoDB() {
        // Configure DynamoDB
        let credentialsProvider = AWSCognitoCredentialsProvider(
            regionType: region,
            identityPoolId: "us-east-1:12345678-1234-1234-1234-123456789012"
        )
        
        let configuration = AWSServiceConfiguration(
            region: region,
            credentialsProvider: credentialsProvider
        )
        
        AWSDynamoDB.register(with: configuration!, forKey: "DynamoDB")
    }
    
    // MARK: - Image Signature Operations
    
    func storeImageSignature(_ signature: String, imageKey: String, completion: @escaping (Error?) -> Void) {
        let item: [String: AWSDynamoDBAttributeValue] = [
            "signature": .init(s: signature),
            "imageKey": .init(s: imageKey),
            "timestamp": .init(n: String(Date().timeIntervalSince1970))
        ]
        
        let request = AWSDynamoDBPutItemInput()
        request.tableName = tableName
        request.item = item
        
        dynamoDB.putItem(request) { response, error in
            completion(error)
        }
    }
    
    func checkForDuplicate(signature: String, perceptualHash: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let queryRequest = AWSDynamoDBQueryInput()
        queryRequest?.tableName = tableName
        queryRequest?.indexName = "SignatureIndex"
        queryRequest?.keyConditionExpression = "signature = :signature"
        queryRequest?.expressionAttributeValues = [
            ":signature": AWSDynamoDBAttributeValue(string: signature)
        ]
        
        dynamoDB.query(queryRequest!) { response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            if let items = response?.items, !items.isEmpty {
                completion(.success(true))
                return
            }
            
            self.checkPerceptualHashSimilarity(perceptualHash) { result in
                switch result {
                case .success(let isSimilar):
                    completion(.success(isSimilar))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func checkPerceptualHashSimilarity(_ hash: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let scanRequest = AWSDynamoDBScanInput()
        scanRequest?.tableName = tableName
        scanRequest?.filterExpression = "perceptual_hash = :hash"
        scanRequest?.expressionAttributeValues = [
            ":hash": AWSDynamoDBAttributeValue(string: hash)
        ]
        
        dynamoDB.scan(scanRequest!) { response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            if let items = response?.items {
                for item in items {
                    if let storedHash = item["perceptual_hash"]?.string {
                        let distance = self.hammingDistance(hash, storedHash)
                        if distance < 10 {
                            completion(.success(true))
                            return
                        }
                    }
                }
            }
            
            completion(.success(false))
        }
    }
    
    func storeSignature(signature: String, perceptualHash: String, imageKey: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let item: [String: AWSDynamoDBAttributeValue] = [
            "signature": AWSDynamoDBAttributeValue(string: signature),
            "perceptual_hash": AWSDynamoDBAttributeValue(string: perceptualHash),
            "image_key": AWSDynamoDBAttributeValue(string: imageKey),
            "timestamp": AWSDynamoDBAttributeValue(string: ISO8601DateFormatter().string(from: Date()))
        ]
        
        let putRequest = AWSDynamoDBPutItemInput()
        putRequest?.tableName = tableName
        putRequest?.item = item
        
        dynamoDB.putItem(putRequest!) { response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            completion(.success(()))
        }
    }
    
    private func hammingDistance(_ str1: String, _ str2: String) -> Int {
        guard str1.count == str2.count else { return Int.max }
        return zip(str1, str2).filter { $0 != $1 }.count
    }
    
    func deleteImageSignature(_ signature: String, completion: @escaping (Error?) -> Void) {
        let request = AWSDynamoDBDeleteItemInput()
        request.tableName = tableName
        request.key = [
            "signature": .init(s: signature)
        ]
        
        dynamoDB.deleteItem(request) { response, error in
            completion(error)
        }
    }
} 
import Foundation
import AWSCore
import AWSDynamoDB
import Logging

/// Manages global image signature checks and storage in DynamoDB
public final class GlobalSignatureService {
    public static let shared = GlobalSignatureService()
    private let client: AWSDynamoDB
    private let tableName = "ImageSignatures"
    private let logger = Logging.Logger(label: "DuplicateSignatureStore")
    
    private init() {
        // Configure AWS with Cognito Identity Pool
        let credentialsProvider = AWSCognitoCredentialsProvider(
            regionType: .USEast1,
            identityPoolId: "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c"
        )
        let config = AWSServiceConfiguration(region: .USEast1, credentialsProvider: credentialsProvider)!
        AWSServiceManager.default().defaultServiceConfiguration = config
        client = AWSDynamoDB.default()
    }
    
    /// Returns true if the signature exists in the global DynamoDB table
    func contains(_ aHash: String) async -> Bool {
        guard let input = AWSDynamoDBGetItemInput() else {
            logger.error("Could not create GetItemInput")
            return false
        }
        input.tableName = tableName
        
        guard let attr = AWSDynamoDBAttributeValue() else {
            logger.error("Could not create AttributeValue")
            return false
        }
        attr.s = aHash
        input.key = ["signature": attr]
        
        return await withCheckedContinuation { cont in
            _ = client.getItem(input).continueWith { task in
                if task.error != nil {
                    cont.resume(returning: false)
                } else {
                    let found = (task.result?.item?.isEmpty == false)
                    cont.resume(returning: found)
                }
                return nil
            }
        }
    }
    
    func store(_ aHash: String) {
        guard let input = AWSDynamoDBPutItemInput() else {
            logger.error("Could not create PutItemInput")
            return
        }
        input.tableName = tableName
        
        guard let hashAttr = AWSDynamoDBAttributeValue(),
              let dateAttr = AWSDynamoDBAttributeValue()
        else {
            logger.error("Could not create AttributeValues")
            return
        }
        
        hashAttr.s = aHash
        dateAttr.s = ISO8601DateFormatter().string(from: Date())
        
        input.item = ["hash": hashAttr, "firstSeen": dateAttr]
        input.conditionExpression = "attribute_not_exists(hash)"
        _ = client.putItem(input)
    }
}

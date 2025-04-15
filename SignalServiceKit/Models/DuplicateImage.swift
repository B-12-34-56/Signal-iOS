import AWSDynamoDB
import Foundation

class DuplicateImageRecord: AWSDynamoDBObjectModel, AWSDynamoDBModeling {
    @objc var signature: String?
    @objc var timestamp: NSNumber?

    // MARK: - AWSDynamoDBModeling
    class func dynamoDBTableName() -> String {
        return "ImageSignatures"  // Placeholder, update the name with the actual table
    }
    
    class func hashKeyAttribute() -> String {
        return "signature"
    }
    
    // MARK: - Duplicate Detection
    func checkGlobalDuplicate(signature: String, completion: @escaping (Bool) -> Void) {
        let mapper = AWSDynamoDBObjectMapper.default()
        
        // Look up the signature in DynamoDB.
        mapper.load(DuplicateImageRecord.self, hashKey: signature, rangeKey: nil) { record, error in
            if let error = error {
                print("Error loading record: \(error)")
                // In case of error, you can choose to fail open (return false) or handle it differently.
                completion(false)
                return
            }
            if let record = record as? DuplicateImageRecord {
                // Duplicate found.
                completion(true)
            } else {
                // No duplicate; create a new record.
                guard let newRecord = DuplicateImageRecord() else {
                    print("Failed to instantiate DuplicateImageRecord")
                    completion(false)
                    return
                }
                newRecord.signature = signature
                newRecord.timestamp = NSNumber(value: Date().timeIntervalSince1970)
                
                mapper.save(newRecord) { error in
                    if let error = error {
                        print("Failed to save record: \(error)")
                        completion(false)
                    } else {
                        completion(false)
                    }
                }
            }
        }
    }
}
//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//


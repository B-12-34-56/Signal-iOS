import Foundation
import AWSDynamoDB

class DuplicateImageRecord: AWSDynamoDBObjectModel, AWSDynamoDBModeling {
  @objc var signature: String?
  @objc var timestamp: NSNumber?
  @objc var isBlocked: NSNumber?
  @objc var senderId:  String?

  class func dynamoDBTableName() -> String {
    return DuplicateDetectionConfig.tableName
  }

  class func hashKeyAttribute() -> String {
    return "signature"
  }

  func checkGlobalDuplicate(signature: String) async throws -> Bool {
    let mapper = AWSDynamoDBObjectMapper.default()
    let cfg = AWSDynamoDBObjectMapperConfiguration()
    // consistentRead is an NSNumber, not Bool
    cfg.consistentRead = NSNumber(value: false)

    // Explicitly annotate the CheckedContinuation type
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
      // Pass configuration separately, not as part of the trailing closure
      mapper.load(
        DuplicateImageRecord.self,
        hashKey: signature,
        rangeKey: nil,
        configuration: cfg) { (rec: Any?, err: Error?) in
          if let e = err {
            cont.resume(throwing: e)
          } else {
            cont.resume(returning: rec != nil)
          }
        }
    }
  }

  func saveToAWS() async throws {
    guard signature != nil else {
      throw NSError(domain: "DupImageRec", code: 1, userInfo: nil)
    }
    timestamp = timestamp ?? NSNumber(value: Date().timeIntervalSince1970)
    isBlocked = isBlocked ?? NSNumber(value: 0)

    let mapper = AWSDynamoDBObjectMapper.default()
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      mapper.save(self) { (err: Error?) in
        if let e = err {
          cont.resume(throwing: e)
        } else {
          cont.resume(returning: ())
        }
      }
    }
  }

  static func blockSignature(_ signature: String) async throws {
    let mapper = AWSDynamoDBObjectMapper.default()
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      mapper.load(
        DuplicateImageRecord.self,
        hashKey: signature,
        rangeKey: nil) { (rec: Any?, err: Error?) in
          if let e = err {
            cont.resume(throwing: e)
          } else if let r = rec as? DuplicateImageRecord {
            r.isBlocked = NSNumber(value: 1)
            mapper.save(r) { (saveErr: Error?) in
              if let se = saveErr {
                cont.resume(throwing: se)
              } else {
                cont.resume(returning: ())
              }
            }
          } else {
            cont.resume(throwing: NSError(domain: "DupImageRec", code: 2, userInfo: [NSLocalizedDescriptionKey: "Record not found"]))
          }
        }
    }
  }
}

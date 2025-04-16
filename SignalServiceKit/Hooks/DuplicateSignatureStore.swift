// DuplicateSignatureStore.swift

import Foundation
import AWSCore
import AWSDynamoDB

public protocol DuplicateSignatureStoreDelegate: AnyObject {
  /// Called on main thread
  func didDetectDuplicate(attachmentId: String, signature: String, originalSender: String)
}

public class DuplicateSignatureStore {
  public static let shared = DuplicateSignatureStore()
  public weak var delegate: DuplicateSignatureStoreDelegate?

  private var cache = [String: SignatureRecord]()
  private let queue = DispatchQueue(label: "dup.sig.store", attributes: .concurrent)
  private var awsEnabled = false

  public func setupDatabase() {
    Logger.info("In‑memory store ready")
    scheduleCleanup()
  }

  public func enableAWSIntegration() {
    awsEnabled = true
    let creds = AWSStaticCredentialsProvider(
      accessKey: DuplicateDetectionConfig.awsAccessKey,
      secretKey: DuplicateDetectionConfig.awsSecretKey
    )
    let config = AWSServiceConfiguration(
      region: DuplicateDetectionConfig.awsRegion,
      credentialsProvider: creds
    )
    AWSServiceManager.default().defaultServiceConfiguration = config
  }

  public func contains(_ signature: String) async -> Bool {
    if containsLocally(signature) { return true }
    guard awsEnabled else { return false }
    do {
      // Create model directly without optionals
      let model = AWSDynamoDBObjectModel.init(dictionary: [:]) as! DuplicateImageRecord
      let isDup = try await model.checkGlobalDuplicate(signature: signature)
      if isDup {
        let record = SignatureRecord(
          attachmentId: "aws_sync",
          senderId:    "aws_sync",
          timestamp:   Date(),
          isBlocked:   false
        )
        addToCache(signature, record: record)
      }
      return isDup
    } catch {
      Logger.error("AWS lookup failed: \(error)")
      return false
    }
  }

  public func store(signature: String, attachmentId: String, senderId: String) {
    let rec = SignatureRecord(
      attachmentId: attachmentId,
      senderId:     senderId,
      timestamp:    Date(),
      isBlocked:    false
    )
    addToCache(signature, record: rec)

    guard awsEnabled else { return }
    Task {
      // Create model directly without optionals
      let model = AWSDynamoDBObjectModel.init(dictionary: [:]) as! DuplicateImageRecord
      model.signature = signature
      model.timestamp = NSNumber(value: Date().timeIntervalSince1970)
      model.senderId  = senderId
      model.isBlocked = NSNumber(value: 0)
      do {
        try await model.saveToAWS()
      } catch {
        Logger.error("Save to AWS failed: \(error)")
      }
    }
  }

  public func block(signature: String) {
    queue.async(flags: .barrier) {
      self.cache[signature]?.isBlocked = true
    }
    if awsEnabled {
      Task {
        do {
          try await DuplicateImageRecord.blockSignature(signature)
        } catch {
          Logger.error("AWS block failed: \(error)")
        }
      }
    }
  }

  public func isBlocked(_ signature: String) -> Bool {
    return queue.sync { cache[signature]?.isBlocked == true }
  }

  public func originalSender(for signature: String) -> String? {
    return queue.sync { cache[signature]?.senderId }
  }

  // MARK: — Private

  public func containsLocally(_ sig: String) -> Bool {
    return queue.sync { cache[sig] != nil }
  }

  private func addToCache(_ sig: String, record: SignatureRecord) {
    queue.async(flags: .barrier) {
      self.cache[sig] = record
    }
  }

  private func scheduleCleanup() {
    queue.asyncAfter(deadline: .now() + .seconds(Int(DuplicateDetectionConfig.cleanupInterval))) {
      self.cleanup()
      self.scheduleCleanup()
    }
  }

  private func cleanup() {
    let cutoff = Date().addingTimeInterval(-Double(DuplicateDetectionConfig.retentionPeriod))
    queue.async(flags: .barrier) {
      self.cache = self.cache.filter {
        $0.value.isBlocked || $0.value.timestamp > cutoff
      }
    }
    Logger.info("Cache cleanup complete")
  }

  public struct SignatureRecord {
    let attachmentId: String
    let senderId:     String
    let timestamp:    Date
    var isBlocked:    Bool
  }
}

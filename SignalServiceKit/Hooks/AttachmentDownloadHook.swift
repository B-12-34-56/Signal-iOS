// AttachmentDownloadHook.swift

import Foundation
import UIKit
import AWSCore
import AWSDynamoDB

extension Notification.Name {
  static let attachmentDownloadDidSucceed     = Notification.Name("attachmentDownloadDidSucceed")
  static let duplicateAttachmentDetected      = Notification.Name("duplicateAttachmentDetected")
}

public class AttachmentDownloadHook {
  public static let shared = AttachmentDownloadHook()
  private let fetcher: AttachmentFetcher = ReflectionAttachmentFetcher()
  private let store = DuplicateSignatureStore.shared

  public func install() {
    Logger.info("Installing DuplicateDetectionHook")
    store.setupDatabase()
    store.enableAWSIntegration()
    testDynamoDBConnectivity()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onDownload(_:)),
      name: .attachmentDownloadDidSucceed,
      object: nil
    )
  }

  private func testDynamoDBConnectivity() {
    let mapper = AWSDynamoDBObjectMapper.default()
    let expr   = AWSDynamoDBScanExpression()
    expr.limit = 1
    mapper.scan(DuplicateImageRecord.self, expression: expr) { out, err in
      if let e = err {
        Logger.error("🔥 DynamoDB scan failed: \(e)")
      } else if let items = out?.items as? [DuplicateImageRecord], !items.isEmpty {
        Logger.info("✅ DynamoDB scan succeeded, found \(items.count) item(s).")
      } else {
        Logger.warn("⚠️ DynamoDB scan returned zero items.")
      }
    }
  }

  @objc private func onDownload(_ note: Notification) {
    guard let id = note.userInfo?["attachmentId"] as? String else { return }
    SSKEnvironment.shared.databaseStorageRef.read { txn in
      Task { await self.process(id: id, txn: txn) }
    }
  }

  private func process(id: String, txn: Any) async {
    guard
      let att  = fetcher.fetch(uniqueId: id, transaction: txn),
      let type = fetcher.contentType(of: att),
      type.hasPrefix("image/"),
      let path = fetcher.filePath(of: att),
      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let img  = UIImage(data: data)
    else { return }

    do {
      let sig = try await DuplicateDetectionManager.shared.digitalSignature(for: img)

      // local check
      if store.containsLocally(sig) {
        handleLocal(sig, attachmentId: id)
        return
      }

      // AWS/global check
      if await store.contains(sig) {
        handleDuplicate(sig, id: id)
      } else {
        store.store(signature: sig, attachmentId: id, senderId: "unknown")
      }
    } catch {
      Logger.error("Signature gen failed: \(error)")
    }
  }

  private func handleLocal(_ sig: String, attachmentId: String) {
    if store.isBlocked(sig) {
      Logger.warn("Attachment \(attachmentId) BLOCKED by policy")
    } else if let original = store.originalSender(for: sig) {
      fireDuplicateNotification(id: attachmentId, sig: sig, original: original)
    }
  }

  private func handleDuplicate(_ sig: String, id: String) {
    if let original = store.originalSender(for: sig) {
      fireDuplicateNotification(id: id, sig: sig, original: original)
    }
  }

  private func fireDuplicateNotification(id: String, sig: String, original: String) {
    Logger.warn("Duplicate detected: \(sig) from \(original)")
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: .duplicateAttachmentDetected,
        object: nil,
        userInfo: [
          "attachmentId":   id,
          "signature":      sig,
          "originalSender": original
        ]
      )
    }
  }
}

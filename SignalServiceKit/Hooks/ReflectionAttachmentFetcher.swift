import Foundation

public protocol AttachmentFetcher {
  func fetch(uniqueId: String, transaction: Any) -> Any?
  func contentType(of attachment: Any) -> String?
  func filePath(of attachment: Any) -> String?
}

import Foundation

public class ReflectionAttachmentFetcher: AttachmentFetcher {
  public init() {}

  public func fetch(uniqueId: String, transaction: Any) -> Any? {
    // Look up the TSAttachmentStream class and selector
    guard
      let cls = NSClassFromString("TSAttachmentStream") as? NSObject.Type,
      cls.responds(to: NSSelectorFromString("anyFetchWithUniqueId:transaction:"))
    else {
      Logger.error("ReflectionAdapter: TSAttachmentStream not available")
      return nil
    }
    // Perform the selector
    let sel = NSSelectorFromString("anyFetchWithUniqueId:transaction:")
    if let result = cls.perform(sel, with: uniqueId, with: transaction) {
      return result.takeUnretainedValue()
    }
    return nil
  }

  public func contentType(of attachment: Any) -> String? {
    guard let obj = attachment as? NSObject else { return nil }
    return obj.value(forKey: "contentType") as? String
  }

  public func filePath(of attachment: Any) -> String? {
    guard let obj = attachment as? NSObject else { return nil }
    let sel = NSSelectorFromString("originalFilePath")
    guard obj.responds(to: sel),
          let result = obj.perform(sel)?.takeUnretainedValue() as? String
    else {
      Logger.error("ReflectionAdapter: originalFilePath not available")
      return nil
    }
    return result
  }
}

import Foundation
import ObjectiveC.runtime

private enum AssocKey { static var hash = "Attachment.aHashString" }

public extension Attachment {
    /// 16-character average-hash used for duplicate detection.
    @objc var aHashString: String? {
        get { objc_getAssociatedObject(self, &AssocKey.hash) as? String }
        set { objc_setAssociatedObject(self, &AssocKey.hash, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

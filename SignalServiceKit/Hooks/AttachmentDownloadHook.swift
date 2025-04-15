import Foundation
import ObjectiveC
import UIKit
import CryptoKit

// MARK: - Custom Notification Name
extension NSNotification.Name {
    public static let attachmentDownloadDidSucceed = NSNotification.Name("attachmentDownloadDidSucceed")
    public static let duplicateAttachmentDetected = NSNotification.Name("duplicateAttachmentDetected")
}

// MARK: - Thread safety utility
private class SignatureLock {
    private let queue = DispatchQueue(label: "org.signal.duplicateSignatureStore", attributes: .concurrent)
    
    func sync<T>(_ block: () -> T) -> T {
        var result: T!
        queue.sync { result = block() }
        return result
    }
    
    func async(flags: DispatchWorkItemFlags = [], _ block: @escaping () -> Void) {
        queue.async(flags: flags, execute: block)
    }
}

// MARK: - DuplicateSignatureStore with AWS Integration
public class DuplicateSignatureStore {
    public static let shared = DuplicateSignatureStore()
    
    // In-memory cache for signatures
    private var signatures: [String: SignatureRecord] = [:]
    private let lock = SignatureLock()
    private var awsEnabled = false
    
    // Model for signature records
    class SignatureRecord {
        let attachmentId: String
        let senderId: String
        let timestamp: Date
        var isBlocked: Bool
        
        init(attachmentId: String, senderId: String, timestamp: Date, isBlocked: Bool) {
            self.attachmentId = attachmentId
            self.senderId = senderId
            self.timestamp = timestamp
            self.isBlocked = isBlocked
        }
    }
    
    public func setupDatabase() {
        // In-memory implementation doesn't need initialization
        Logger.info("Using in-memory signature store")
    }
    
    public func enableAWSIntegration() {
        awsEnabled = true
        Logger.info("AWS integration enabled for duplicate detection")
        
        // Set up AWS configuration here
        let credentialsProvider = AWSStaticCredentialsProvider(
            accessKey: "YOUR_ACCESS_KEY",
            secretKey: "YOUR_SECRET_KEY"
        )
        
        let configuration = AWSServiceConfiguration(
            region: .USEast1, // Use your region
            credentialsProvider: credentialsProvider
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
    
    // Asynchronous method to check both local and AWS
    public func containsSignature(_ signature: String, completion: @escaping (Bool) -> Void) {
        // First check local cache
        let localExists = lock.sync { signatures[signature] != nil }
        if localExists {
            completion(true)
            return
        }
        
        // If AWS is enabled, check there too
        if awsEnabled {
            let record = DuplicateImageRecord()
            record.checkGlobalDuplicate(signature: signature) { isDuplicate in
                if isDuplicate {
                    // If found in AWS, add to local cache for future reference
                    self.addToLocalCache(signature: signature)
                }
                completion(isDuplicate)
            }
        } else {
            completion(false)
        }
    }
    
    // Synchronous method for local-only checks (used for fast path)
    public func containsSignatureLocally(_ signature: String) -> Bool {
        return lock.sync { signatures[signature] != nil }
    }
    
    // Helper to add a signature to local cache when found in AWS
    private func addToLocalCache(signature: String) {
        lock.async(flags: .barrier) {
            // If not already in cache, add it with placeholder values
            if self.signatures[signature] == nil {
                self.signatures[signature] = SignatureRecord(
                    attachmentId: "aws_sync",
                    senderId: "aws_sync",
                    timestamp: Date(),
                    isBlocked: false
                )
            }
        }
    }
    
    public func storeSignature(
        signature: String,
        attachmentId: String,
        senderId: String
    ) {
        // Store locally
        lock.async(flags: .barrier) {
            self.signatures[signature] = SignatureRecord(
                attachmentId: attachmentId,
                senderId: senderId,
                timestamp: Date(),
                isBlocked: false
            )
            Logger.info("Stored new image signature: \(signature)")
        }
        
        // Store in AWS if enabled
        if awsEnabled {
            let record = DuplicateImageRecord()
            record.signature = signature
            record.timestamp = NSNumber(value: Date().timeIntervalSince1970)
            
            let mapper = AWSDynamoDBObjectMapper.default()
            mapper.save(record) { error in
                if let error = error {
                    Logger.error("Failed to save signature to AWS: \(error)")
                } else {
                    Logger.info("Successfully stored signature in AWS: \(signature)")
                }
            }
        }
    }
    
    public func blockSignature(_ signature: String) {
        // Block locally
        lock.async(flags: .barrier) {
            if let record = self.signatures[signature] {
                record.isBlocked = true
                Logger.info("Blocked image signature: \(signature)")
            }
        }
        
        // Block in AWS if enabled
        if awsEnabled {
            // Update the record in DynamoDB to mark it as blocked
            // Implementation depends on your DynamoDB schema
            Logger.info("Blocking signature in AWS: \(signature)")
        }
    }
    
    public func isSignatureBlocked(_ signature: String) -> Bool {
        return lock.sync { signatures[signature]?.isBlocked == true }
    }
    
    public func getSenderForSignature(_ signature: String) -> String? {
        return lock.sync { signatures[signature]?.senderId }
    }
    
    public func cleanupOldSignatures(olderThan date: Date) {
        lock.async(flags: .barrier) {
            // Remove signatures that aren't blocked and are older than the date
            self.signatures = self.signatures.filter { _, record in
                record.isBlocked || record.timestamp > date
            }
            Logger.info("Cleaned up old image signatures")
        }
    }
}

// MARK: - AttachmentDownloadHook Implementation
public class AttachmentDownloadHook: NSObject {
    @objc
    public static let shared = AttachmentDownloadHook()
    
    @objc
    public func install() {
        Logger.info("Installing attachment download hooks for duplicate detection")
        
        // Setup storage for image signatures
        DuplicateSignatureStore.shared.setupDatabase()
        
        // Enable AWS integration if desired
        // Comment out this line if you don't want to use AWS
        DuplicateSignatureStore.shared.enableAWSIntegration()
        
        // Set up method swizzling
        setupAttachmentDownloadManagerHook()
        
        // Register for notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePossibleAttachmentDownload(_:)),
            name: .attachmentDownloadDidSucceed,
            object: nil
        )
    }
    
    // Use NSClassFromString to safely get the concrete class for swizzling.
    private func setupAttachmentDownloadManagerHook() {
        // Look for the class in the current runtime
        guard let originalClass: AnyClass = NSClassFromString("AttachmentDownloadManager") else {
            Logger.warn("AttachmentDownloadManager class not found")
            return
        }
        
        let originalSelector = NSSelectorFromString("attachmentDownloadDidSucceed:")
        let swizzledSelector = #selector(handleAttachmentDownload(_:))
        
        guard let originalMethod = class_getInstanceMethod(originalClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(AttachmentDownloadHook.self, swizzledSelector) else {
            Logger.warn("Could not find methods to swizzle for duplicate detection")
            return
        }
        
        // Add the swizzled method to the original class.
        let didAddMethod = class_addMethod(
            originalClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
        
        if didAddMethod {
            if let replacement = class_getInstanceMethod(originalClass, swizzledSelector) {
                method_exchangeImplementations(originalMethod, replacement)
                Logger.info("Successfully installed duplicate detection hook")
            }
        } else {
            Logger.warn("Failed to install duplicate detection hook")
        }
    }
    
    // The swizzled method - use NSObject to handle any type of attachment
    @objc dynamic func handleAttachmentDownload(_ attachment: Any) {
        Logger.info("Attachment download detected")
        
        // Determine the actual type of attachment and handle appropriately
        if let attachmentId = getAttachmentId(from: attachment) {
            processAttachment(attachmentId: attachmentId)
        }
    }
    
    // Extract attachment ID safely from various possible attachment types
    private func getAttachmentId(from attachment: Any) -> String? {
        // Introspect the object to find its ID property safely
        if let object = attachment as? NSObject {
            if object.responds(to: #selector(getter: TSAttachment.uniqueId)) {
                return object.value(forKey: "uniqueId") as? String
            }
            
            // Try alternate property names
            if object.responds(to: NSSelectorFromString("attachmentId")) {
                return object.value(forKey: "attachmentId") as? String
            }
        }
        
        Logger.warn("Could not extract attachment ID from \(type(of: attachment))")
        return nil
    }
    
    // Handle notifications posted when an attachment download succeeds.
    @objc private func handlePossibleAttachmentDownload(_ notification: Notification) {
        guard let attachmentId = notification.userInfo?["attachmentId"] as? String else {
            Logger.warn("No attachment ID in notification")
            return
        }
        
        processAttachment(attachmentId: attachmentId)
    }
    
    // Process the downloaded attachment by its ID
    private func processAttachment(attachmentId: String) {
        Logger.info("Processing attachment: \(attachmentId)")
        
        // Use Signal's database transaction to access the attachment
        SSKEnvironment.shared.databaseStorageRef.read { transaction in
            self.checkForDuplicate(attachmentId: attachmentId, transaction: transaction)
        }
    }
    
    // Check if the attachment is a duplicate
    private func checkForDuplicate(attachmentId: String, transaction: Any) {
        Logger.info("Checking for duplicates of attachment: \(attachmentId)")
        
        // 1. Get image data from the attachment
        guard let imageData = getImageDataFromAttachment(attachmentId: attachmentId, transaction: transaction) else {
            Logger.debug("Skipping duplicate check - not an image or couldn't get data")
            return
        }
        
        // 2. Generate a signature for the image
        guard let signature = generateImageSignature(from: imageData) else {
            Logger.warn("Could not generate signature for attachment: \(attachmentId)")
            return
        }
        Logger.debug("Generated signature for image: \(signature)")
        
        // 3. Get sender information
        guard let senderId = getSenderIdForAttachment(attachmentId: attachmentId, transaction: transaction) else {
            Logger.warn("Could not determine sender for attachment: \(attachmentId)")
            return
        }
        
        // 4. First check locally (fast path)
        if DuplicateSignatureStore.shared.containsSignatureLocally(signature) {
            handleLocalDuplicate(signature: signature, attachmentId: attachmentId, senderId: senderId)
            return
        }
        
        // 5. Check on AWS if not found locally (slow path)
        DuplicateSignatureStore.shared.containsSignature(signature) { isDuplicate in
            if isDuplicate {
                DispatchQueue.main.async {
                    self.handleDuplicateAttachment(
                        attachmentId: attachmentId,
                        signature: signature,
                        originalSender: "another user"
                    )
                }
            } else {
                // New image - store its signature locally and in AWS
                DuplicateSignatureStore.shared.storeSignature(
                    signature: signature,
                    attachmentId: attachmentId,
                    senderId: senderId
                )
            }
        }
    }
    
    // Helper to get image data from an attachment - adapt this to Signal's actual model
    private func getImageDataFromAttachment(attachmentId: String, transaction: Any) -> Data? {
        // This code should be adapted to Signal's actual data model
        // Example using reflection to safely access the needed methods
        guard let attachment = fetchAttachmentViaReflection(attachmentId: attachmentId, transaction: transaction) else {
            return nil
        }
        
        // Check if it's an image
        guard let contentType = getContentType(from: attachment),
              contentType.hasPrefix("image/") else {
            return nil
        }
        
        // Get file path and read data
        guard let filePath = getFilePath(from: attachment),
              FileManager.default.fileExists(atPath: filePath) else {
            return nil
        }
        
        do {
            // Read the image data
            return try Data(contentsOf: URL(fileURLWithPath: filePath))
        } catch {
            Logger.error("Error reading image data: \(error)")
            return nil
        }
    }
    
    // Helper methods to safely access attachment properties via reflection
    private func fetchAttachmentViaReflection(attachmentId: String, transaction: Any) -> Any? {
        // Try to find the attachment using Signal's API through reflection
        if let transactionClass = type(of: transaction) as? AnyClass {
            let fetchSelectorName = "anyFetchWithUniqueId:transaction:"
            let fetchSelector = NSSelectorFromString(fetchSelectorName)
            
            // Find the TSAttachmentStream class by name
            if let attachmentClass = NSClassFromString("TSAttachmentStream") as? NSObject.Type,
               attachmentClass.responds(to: fetchSelector) {
                
                // Invoke the method via reflection
                let result = attachmentClass.perform(fetchSelector, with: attachmentId, with: transaction)
                return result?.takeUnretainedValue()
            }
        }
        
        Logger.debug("Could not fetch attachment: \(attachmentId) via reflection")
        return nil
    }
    
    private func getContentType(from attachment: Any) -> String? {
        if let object = attachment as? NSObject,
           object.responds(to: NSSelectorFromString("contentType")) {
            return object.value(forKey: "contentType") as? String
        }
        return nil
    }
    
    private func getFilePath(from attachment: Any) -> String? {
        if let object = attachment as? NSObject {
            // Try as a method first
            if object.responds(to: NSSelectorFromString("originalFilePath")) {
                let result = object.perform(NSSelectorFromString("originalFilePath"))
                return result?.takeUnretainedValue() as? String
            }
            
            // Then try as a property
            if object.responds(to: NSSelectorFromString("originalFilePath")) {
                return object.value(forKey: "originalFilePath") as? String
            }
        }
        return nil
    }
    
    // Generate a signature for the image data using perceptual hashing
    private func generateImageSignature(from imageData: Data) -> String? {
        guard let image = UIImage(data: imageData) else {
            Logger.warn("Could not create UIImage from attachment data")
            return nil
        }
        
        // Use the perceptual hash from DuplicateDetectionManager
        return DuplicateDetectionManager.shared.digitalSignature(for: image)
    }
    
    // Helper to get the sender ID for an attachment
    private func getSenderIdForAttachment(attachmentId: String, transaction: Any) -> String? {
        // In a production implementation, this would:
        // 1. Find the TSMessage containing this attachment
        // 2. Get the sender ID from the message
        
        // For now, return a placeholder value
        return "unknown_sender"
    }
    
    private func handleLocalDuplicate(signature: String, attachmentId: String, senderId: String) {
        // If this signature is blocked, handle accordingly
        if DuplicateSignatureStore.shared.isSignatureBlocked(signature) {
            // Block this attachment from being displayed
            handleBlockedAttachment(attachmentId: attachmentId, signature: signature)
        } else {
            // Get the original sender to see if it's from the same sender
            let originalSender = DuplicateSignatureStore.shared.getSenderForSignature(signature)
            
            // If it's from a different sender, it's a duplicate we care about
            if originalSender != nil && originalSender != senderId {
                // It's a duplicate from a different sender - notify the user
                handleDuplicateAttachment(
                    attachmentId: attachmentId,
                    signature: signature,
                    originalSender: originalSender ?? "unknown"
                )
            } else {
                // Same sender or unknown sender - just log it
                Logger.debug("Detected duplicate image from same sender with signature: \(signature)")
            }
        }
    }
    
    // Handle a duplicate attachment
    private func handleDuplicateAttachment(attachmentId: String, signature: String, originalSender: String) {
        Logger.warn("Detected duplicate image with signature: \(signature) originally from sender: \(originalSender)")
        
        // Post a notification so UI can respond with a warning
        NotificationCenter.default.post(
            name: .duplicateAttachmentDetected,
            object: nil,
            userInfo: [
                "attachmentId": attachmentId,
                "signature": signature,
                "originalSender": originalSender
            ]
        )
    }
    
    // Handle a blocked attachment
    private func handleBlockedAttachment(attachmentId: String, signature: String) {
        Logger.warn("Blocked image with signature: \(signature)")
        
        // In a production implementation, you would:
        // 1. Mark the attachment as blocked in the database
        // 2. Possibly delete the attachment file
        // 3. Notify the UI to display a placeholder instead
    }
}

// Placeholder for Signal's TSAttachment class
@objc(TSAttachment)
public class TSAttachment: NSObject {
    @objc
    public var uniqueId: String?
    
    @objc
    public var contentType: String = ""
    
    @objc
    public static func anyFetch(uniqueId: String, transaction: Any) -> Any? {
        // This would be implemented in Signal's actual codebase
        return nil
    }
}

// Placeholder for Signal's TSAttachmentStream class
@objc(TSAttachmentStream)
public class TSAttachmentStream: TSAttachment {
    @objc
    public func originalFilePath() -> String? {
        return nil
    }
}

// DuplicateDetection/AttachmentProcessor.swift

import Foundation
import SignalServiceKit
import SignalUI

class AttachmentProcessor {
    static let shared = AttachmentProcessor()
    
    func setup() {
        Logger.debug("Setting up AttachmentProcessor for duplicate detection")
        
        // Register for attachment download notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAttachmentDownloaded(_:)),
            name: .attachmentDownloadJobCompleted,
            object: nil
        )
        
        Logger.info("AttachmentProcessor setup complete")
    }
    
    @objc
    private func handleAttachmentDownloaded(_ notification: Notification) {
        // Get the attachment from the notification
        guard let attachmentID = notification.userInfo?["attachmentId"] as? String else {
            return
        }
        
        Logger.debug("Handling downloaded attachment with ID: \(attachmentID)")
        
        // Process on a background thread
        Task {
            await SSKEnvironment.shared.databaseStorageRef.read { transaction in
                guard let attachment = TSAttachment.anyFetch(uniqueId: attachmentID, transaction: transaction),
                      let attachmentStream = attachment as? TSAttachmentStream,
                      attachmentStream.isImage,
                      let filePath = attachmentStream.originalFilePath else {
                    return
                }
                
                // Get the thread ID
                let threadId = attachment.uniqueThreadId ?? ""
                
                Logger.debug("Processing image attachment in thread: \(threadId)")
                
                // Process for duplicate detection
                let fileURL = URL(fileURLWithPath: filePath)
                do {
                    let data = try Data(contentsOf: fileURL)
                    let hash = ImageHasher.shared.hash(data).hash
                    
                    // Check if this is a duplicate
                    if try await GlobalSignatureService.shared.checkHashExists(hash) {
                        // This is a duplicate, mark the message as blocked
                        if let message = attachment.associatedMessage(transaction: transaction) {
                            message.update(withIsBlocked: true, transaction: transaction)
                            
                            // Show notification to user
                            DispatchQueue.main.async {
                                self.showBlockedImageNotification(threadId: threadId)
                            }
                        }
                    } else {
                        // Not a duplicate, store the hash
                        try? await GlobalSignatureService.shared.storeHash(hash)
                    }
                } catch {
                    Logger.error("Error processing attachment: \(error)")
                }
            }
        }
    }
    
    private func showBlockedImageNotification(threadId: String) {
        let body = "An image was blocked because it matches content that has been flagged as duplicate."
        let notificationTitle = "Blocked Image"
        
        let actionSheet = ActionSheetController(title: notificationTitle, message: body)
        
        // Add dismiss option
        let dismissAction = ActionSheetAction(title: "Dismiss", style: .cancel)
        actionSheet.addAction(dismissAction)
        
        // Present the action sheet
        UIApplication.shared.frontmostViewController?.presentActionSheet(actionSheet)
    }
}
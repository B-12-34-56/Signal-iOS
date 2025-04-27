//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Logging
import CryptoKit
import SignalServiceKit

/// A class that validates attachments against the global signature database before downloading
public final class AttachmentDownloadHook {
    public static let shared = AttachmentDownloadHook()
    
    private var databasePool: DatabasePool?
    private let logger = Logger(label: "org.signal.AttachmentDownloadHook")
    private let signatureService = GlobalSignatureService.shared
    
    private init() {}
    
    /// Install the hook with the provided database pool
    /// - Parameter pool: The database connection pool
    public func install(with pool: DatabasePool) {
        self.databasePool = pool
        logger.info("Successfully installed attachment validation hook with database pool")
    }
    
    /// Validates an attachment against the global hash database
    /// - Parameters:
    ///   - attachment: The attachment to validate
    ///   - hash: The hash of the attachment content (if already computed)
    /// - Returns: A boolean indicating if the attachment is allowed to download
    public func validateAttachment(_ attachment: TSAttachment, hash: String? = nil) async -> Bool {
        guard let databasePool = databasePool else {
            logger.warning("Database pool not configured, skipping attachment validation")
            return true
        }
        
        // If we already have a hash, use it directly
        if let hash = hash {
            return await validateHash(hash, attachmentId: attachment.uniqueId)
        }
        
        // Otherwise compute hash from the attachment content if available
        if let fileData = try? attachment.dataForDownload() {
            let contentHash = computeAttachmentHash(fileData)
            return await validateHash(contentHash, attachmentId: attachment.uniqueId)
        }
        
        // If we can't compute the hash, allow the download by default
        logger.info("Unable to compute hash for attachment, allowing download")
        return true
    }
    
    /// Validates a hash against the global database
    /// - Parameters:
    ///   - hash: The hash to validate
    ///   - attachmentId: Optional attachment ID for logging
    /// - Returns: A boolean indicating if the hash is allowed
    private func validateHash(_ hash: String, attachmentId: String?) async -> Bool {
        do {
            let exists = await signatureService.contains(hash)
            if exists {
                logger.warning("Blocked attachment download: hash \(hash) found in database (attachmentId: \(attachmentId ?? "unknown"))")
                
                // Report the block to analytics/metrics if needed
                Task {
                    try await reportBlockedAttachment(hash: hash, attachmentId: attachmentId)
                }
                
                return false
            } else {
                return true
            }
        } catch {
            // On error, default to allowing the download
            logger.error("Error checking hash in database: \(error.localizedDescription)")
            return true
        }
    }
    
    /// Computes a hash for the attachment data
    /// - Parameter data: The raw attachment data
    /// - Returns: A base64 encoded string of the hash
    private func computeAttachmentHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }
    
    /// Reports a blocked attachment to the analytics service
    /// - Parameters:
    ///   - hash: The hash that was blocked
    ///   - attachmentId: The attachment ID if available
    private func reportBlockedAttachment(hash: String, attachmentId: String?) async throws {
        // This is a placeholder for analytics/metrics reporting
        // In production, this would send telemetry data about blocked attachments
        logger.info("Reporting blocked attachment: hash \(hash), attachmentId: \(attachmentId ?? "unknown")")
    }
    
    /// Add a known bad hash to the database for testing
    /// - Parameter hash: The hash to add to the blocked list
    public func addKnownBadHashForTesting(_ hash: String) {
        Task {
            await signatureService.store(hash)
        }
    }
    
    /// Generates a new random testing hash
    /// - Returns: A unique hash string for testing
    public func generateTestingHash() -> String {
        let randomData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return randomData.base64EncodedString()
    }
}
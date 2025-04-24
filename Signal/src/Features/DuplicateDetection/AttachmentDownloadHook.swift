// AttachmentDownloadHook.swift
// Processes both incoming and outgoing attachments with local & global duplicate checks.

import Foundation
import UIKit
import GRDB
import os.log
import SignalServiceKit

// MARK: - Model
struct SignalAttachmentRecord: FetchableRecord, Decodable, Identifiable, TableRecord {
    var id: Int64
    var uniqueId: String?
    var localRelativeFilePath: String?
    var senderId: String?
    var isOutgoing: Bool?
    var contentType: String?
    var isProcessedForDuplicateCheck: Bool?

    static let databaseTableName = "Attachment"
}

// MARK: - Hook
final class AttachmentDownloadHook {
    static let shared = AttachmentDownloadHook()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AttachmentDownloadHook")
    private let signatureStore = DuplicateSignatureStore.shared
    private let fileManager = FileManager.default
    private let appGroupID = "group.com.joelminaya.signaldev"
    private var attachmentObservation: DatabaseCancellable?
    private var dbPool: DatabasePool?

    private init() {}

    /// Install hook once your GRDB pool is ready
    func install(with dbPool: DatabasePool) {
        self.dbPool = dbPool
        Task { await signatureStore.setupDatabase(in: dbPool) }
        startObservation(dbPool: dbPool)
    }

    // ── startObservation ─────────────────────────────────────────────────────────────
    private func startObservation(dbPool: DatabasePool) {
        logger.info("AttachmentDownloadHook observation started ✅")

        let obs = ValueObservation.tracking { db in
            try SignalAttachmentRecord
                .filter(Column("contentType").like("image/%"))
                .filter(Column("localRelativeFilePath") != nil)
                .filter(Column("isProcessedForDuplicateCheck") == false)
                .fetchAll(db)
        }
        attachmentObservation = obs.start(
            in: dbPool,
            onError: { error in self.logger.error("Obs error: \(error)") },
            onChange: { recs in if !recs.isEmpty { self.handle(recs) } }
        )
    }

    private func handle(_ attachments: [SignalAttachmentRecord]) {
        print("👀 Hook got \(attachments.count) attachment(s)")
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }
        for rec in attachments {
            guard let path = rec.localRelativeFilePath, let sender = rec.senderId else { continue }
            let url = container.appendingPathComponent(path)

            Task {
                do {
                    // Compute both hashes
                    let image = UIImage(contentsOfFile: url.path)!
                    let visionHash = try await DuplicateDetectionManager.shared.digitalSignature(for: image)
                    let aHash      = HashUtils.averageHash8x8(image)

                    if rec.isOutgoing == true {
                        // Outgoing: run full local/global check
                        try await processOutgoing(
                            signature: visionHash,
                            aHash: aHash,
                            attachmentId: rec.uniqueId ?? "\(rec.id)",
                            senderId: sender
                        )
                    } else {
                        // Incoming: just store locally (no block)
                        signatureStore.store(
                            signature: visionHash,
                            aHash: aHash,
                            attachmentId: rec.uniqueId ?? "\(rec.id)",
                            senderId: sender
                        )
                    }
                    await markProcessed(id: rec.id)
                } catch {
                    logger.error("Duplicate blocked for attachment \(rec.id): \(error.localizedDescription)")
                    // ❸ Re-throw so upstream layers may cancel the send throw error
                }
            }
        }
    }

    private func markProcessed(id: Int64) async {
        guard let pool = dbPool else { return }
        try? await pool.write { db in
            try db.execute(
                sql: "UPDATE Attachment SET isProcessedForDuplicateCheck = ? WHERE id = ?",
                arguments: [true, id]
            )
        }
    }

    /// Handles outgoing images with both Vision and aHash checks
    private func processOutgoing(
        signature visionHash: String,
        aHash: String,
        attachmentId: String,
        senderId: String
    ) async throws {
        // 1) Local blocked?
        if await signatureStore.isBlocked(aHash) {
            throw NSError(domain: "AttachmentProcessing", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "Duplicate blocked (local)"])
        }
        // 2) Local duplicate?
        else if await signatureStore.contains(aHash) {
            signatureStore.block(signature: aHash)
            DispatchQueue.main.async {
                self.signatureStore.delegate?.didDetectDuplicate(
                    attachmentId: attachmentId,
                    signature: aHash,
                    originalSender: senderId
                )
            }
            throw NSError(domain: "AttachmentProcessing", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "Duplicate detected (local)"])
        }
        // 3) Global duplicate?
        else if await GlobalSignatureService.shared.contains(aHash) {
            signatureStore.block(signature: aHash)
            DispatchQueue.main.async {
                self.signatureStore.delegate?.didDetectDuplicate(
                    attachmentId: attachmentId,
                    signature: aHash,
                    originalSender: "(already sent)"
                )
            }
            throw NSError(domain: "AttachmentProcessing", code: 102,
                          userInfo: [NSLocalizedDescriptionKey: "Duplicate detected (global)"])
        }
        // 4) New image: store both locally & globally
        else {
            signatureStore.store(
                signature: visionHash,
                aHash: aHash,
                attachmentId: attachmentId,
                senderId: senderId
            )
            GlobalSignatureService.shared.store(aHash)
        }
    }
}

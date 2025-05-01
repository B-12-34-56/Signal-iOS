//  AttachmentDownloadHook.swift
//  Processes both incoming and outgoing attachments with local & global duplicate checks.

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

    private let logger          = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AttachmentDownloadHook")
    private let signatureStore  = DuplicateSignatureStore.shared
    private let attachmentDownloadStore = DependenciesBridge.shared.attachmentDownloadStore
    private let fileManager     = FileManager.default
    private let appGroupID      = "group.com.joelminaya.signaldev"

    private var attachmentObservation: DatabaseCancellable?
    private var dbPool: DatabasePool?

    private init() { }

    // Call from AppDelegate once the app’s GRDB pool is ready
    func install(with dbPool: DatabasePool) {
        self.dbPool = dbPool
        Task { await signatureStore.setupDatabase(in: dbPool) }
        startObservation(dbPool: dbPool)
    }

    // ──────────────────────────────────────────────────────────────────────────────
    private func startObservation(dbPool: DatabasePool) {
        logger.info("AttachmentDownloadHook observation started ✅")

        let obs = ValueObservation.tracking { db in
            try SignalAttachmentRecord
                .filter(Column("contentType").like("image/%"))
                .filter(Column("localRelativeFilePath") != nil)
                .filter(
                    Column("isProcessedForDuplicateCheck") == false
                    || Column("isProcessedForDuplicateCheck") == nil
                )
                .fetchAll(db)
        }

        attachmentObservation = obs.start(
            in: dbPool,
            onError: { [logger] error in logger.error("Obs error: \(error)") },
            onChange: { [weak self] records in
                guard let self, !records.isEmpty else { return }
                self.handle(records)
            }
        )
    }

    // MARK: – Per attachment
    private func handle(_ attachments: [SignalAttachmentRecord]) {
        guard
            let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }

        for rec in attachments {
            guard
                let path   = rec.localRelativeFilePath,
                let sender = rec.senderId
            else { continue }

            let url = container.appendingPathComponent(path)

            // Process each attachment in its own task
            Task { [weak self] in
                guard let self else { return }

                do {
                    guard let image = UIImage(contentsOfFile: url.path) else { return }

                    let vision = try await DuplicateDetectionManager.shared.digitalSignature(for: image)
                    let aHash  = HashUtils.averageHash8x8(image)

                    if rec.isOutgoing == true {
                        try await self.processOutgoing(
                            signature:   vision,
                            aHash:        aHash,
                            attachmentId: rec.uniqueId ?? "\(rec.id)",
                            senderId:     sender
                        )
                    } else {
                        self.signatureStore.store(
                            signature:   vision,
                            aHash:        aHash,
                            attachmentId: rec.uniqueId ?? "\(rec.id)",
                            senderId:     sender
                        )
                    }

                    await self.markProcessed(id: rec.id)

                } catch {
                    self.logger.error("Duplicate blocked for \(rec.id): \(error.localizedDescription)")
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

    // MARK: – Outgoing-image checks
    private func processOutgoing(
        signature visionHash: String,
        aHash: String,
        attachmentId: String,
        senderId: String
    ) async throws {

        // 1️⃣ Already blocked locally?
        if await signatureStore.isBlocked(aHash) {
            throw DuplicateError.localBlocked
        }

        // 2️⃣ Duplicate in local DB?
        if await signatureStore.contains(aHash) {
            signatureStore.block(signature: aHash)
            try await dbPool?.write { db in
                try self.attachmentDownloadStore   // ← add **self.**
                    .markAttachmentBlocked(id: Int64(attachmentId) ?? 0, db: db)
            }
            DispatchQueue.main.async {
                self.signatureStore.delegate?.didDetectDuplicate(
                    attachmentId: attachmentId,
                    signature:    aHash,
                    originalSender: senderId
                )
            }
            throw DuplicateError.localDuplicate
        }

        // 3️⃣ Global duplicate
        if await GlobalSignatureService.shared.contains(aHash) {
            signatureStore.block(signature: aHash)
            try await dbPool?.write { db in
                try self.attachmentDownloadStore   // ← add **self.**
                    .markAttachmentBlocked(id: Int64(attachmentId) ?? 0, db: db)
            }
            DispatchQueue.main.async {
                self.signatureStore.delegate?.didDetectDuplicate(
                    attachmentId: attachmentId,
                    signature:    aHash,
                    originalSender: "(already sent)"
                )
            }
            throw DuplicateError.globalDuplicate
        }

        // 4️⃣ Brand-new image – store locally + globally
        signatureStore.store(
            signature:   visionHash,
            aHash:       aHash,
            attachmentId: attachmentId,
            senderId:    senderId
        )
        GlobalSignatureService.shared.store(aHash)
    }
}

// Convenience error enum
private enum DuplicateError: Error {
    case localBlocked, localDuplicate, globalDuplicate
}

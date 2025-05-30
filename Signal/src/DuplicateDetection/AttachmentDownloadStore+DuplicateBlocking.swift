//
//  AttachmentDownloadStore+DuplicateBlocking.swift
//

import Foundation
import GRDB
import SignalServiceKit     // exposes `AttachmentDownloadStore` + `QueuedAttachmentDownloadRecord`

// MARK: – helper
extension QueuedAttachmentDownloadRecord {
    /// Terminal value for "don't retry me" in `AttachmentDownloadQueue.state`
    static let blockedState = "blocked"
}

extension AttachmentDownloadStore {

    // ────────────────  NO-OP stubs the runner still expects  ────────────────
    func fetchRetryableDownloads(tx: Database, beforeOrAt timestamp: Int64) throws -> [QueuedAttachmentDownloadRecord] { [] }

    func updateRetryAttemptNoOp(id: Int64,
                            newTimestamp: Int64,
                            newAttemptCount: Int,
                            db: Database) throws { /* no-op */ }

    func markReadyForDownload(id: Int64, db: Database) throws { /* no-op */ }

    func nextRetryTimestamp(db: Database) throws -> UInt64? { nil }

    // ───────────────────────  NEW helper used by the hook  ───────────────────────
    /// Marks a queue row as permanently blocked (never retried or re-downloaded).
    func markAttachmentBlocked(id: Int64, db: Database) throws {
        try db.execute(
            sql: """
                 UPDATE AttachmentDownloadQueue
                    SET state            = ?,
                        minRetryTimestamp = NULL   -- prevents automatic retries
                  WHERE id = ?
                 """,
            arguments: [QueuedAttachmentDownloadRecord.blockedState, id]
        )
    }
}

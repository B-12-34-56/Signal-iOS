// DuplicateDetectionStore.swift
// Implements local GRDB storage for image signature deduplication.

import Foundation
import GRDB
import Logging

// MARK: – Notification name

extension Notification.Name {

    static let duplicateBlocked = Notification.Name("DuplicateBlocked")
}

// MARK: - Delegate Protocol
protocol DuplicateSignatureStoreDelegate: AnyObject {
    /// Called on main thread when a duplicate is detected locally.
    func didDetectDuplicate(attachmentId: String, signature: String, originalSender: String)
}

// MARK: - Local DB Model
struct LocalImageSignature: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String         // PRIMARY KEY: aHash hex
    var visionId: String?  // optional Vision‑SHA256
    var timestamp: Date
    var senderId: String
    var isBlocked: Bool

    static let databaseTableName = "ImageSignatures"
}


// MARK: - Store
class DuplicateSignatureStore {
    static let shared = DuplicateSignatureStore()
    weak var delegate: DuplicateSignatureStoreDelegate?

    // Fully-qualified to force the Swift-Log type if needed
        private let logger = Logging.Logger(
            label: Bundle.main.bundleIdentifier ?? "DuplicateSignatureStore"
            )
    private var dbPool: DatabasePool!

    private init() {}

    /// Call once at app launch to create the table and schedule cleanup
    func setupDatabase(in dbPool: DatabasePool) async {
        self.dbPool = dbPool
        do {
            try await dbPool.write { db in
                try db.create(table: LocalImageSignature.databaseTableName, ifNotExists: true) { t in
                    t.column("id", .text).primaryKey()
                    t.column("visionId", .text)
                    t.column("timestamp", .datetime).notNull()
                    t.column("senderId", .text).notNull()
                    t.column("isBlocked", .boolean).notNull().defaults(to: false)
                }
            }
            logger.info("Local duplicate signature DB setup complete.")
            scheduleCleanup()
        } catch {
            logger.error("Local DB setup failed: \(error.localizedDescription)")
        }
    }

    /// Returns true if the signature exists locally
    func contains(_ aHash: String) async -> Bool {
        // 1) Exact match
        if (try? await dbPool.read({ try LocalImageSignature.fetchOne($0, key: aHash) })) != nil {
            return true
        }
        // 2) Fuzzy match via Hamming distance
        let all = (try? await dbPool.read({ try LocalImageSignature.fetchAll($0) })) ?? []
        for rec in all {
            if HashUtils.isSimilar(rec.id, aHash) {
                return true
            }
        }
        return false
    }


    /// Stores a new signature locally
    func store(signature visionId: String, aHash: String, attachmentId: String, senderId: String) {
        let rec = LocalImageSignature(
            id:        aHash,
            visionId:  visionId,
            timestamp: Date(),
            senderId:  senderId,
            isBlocked: false
        )
        Task {
            try await dbPool.write { db in
                try rec.insert(db)
            }
            logger.info("Stored local aHash: \(aHash.prefix(8))…")
        }
    }


    /// Marks a signature as blocked locally
    func block(signature: String) {
        Task {
            do {
                try await dbPool.write { db in
                    if var rec = try LocalImageSignature.fetchOne(db, key: signature) {
                        rec.isBlocked = true
                        try rec.update(db)
                    }
                }
                logger.info("Blocked local signature: \(signature.prefix(8))...")
                // ❶ Notify listeners (MessageSender / UI) that a block happened
                NotificationCenter.default.post(name: .duplicateBlocked, object: signature)
            } catch {
                logger.error("Failed blocking signature: \(error.localizedDescription)")
            }
        }
    }

    /// Returns true if the signature is blocked locally
    func isBlocked(_ signature: String) async -> Bool {
        do {
            let rec = try await dbPool.read { db in
                try LocalImageSignature.fetchOne(db, key: signature)
            }
            let blocked = rec?.isBlocked ?? false
            logger.debug("Signature \(signature.prefix(8))... is\(blocked ? "" : " not") blocked locally.")
            return blocked
        } catch {
            logger.error("Error checking block status: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns the original sender for the signature
    func originalSender(for signature: String) async -> String? {
        do {
            let rec = try await dbPool.read { db in
                try LocalImageSignature.fetchOne(db, key: signature)
            }
            return rec?.senderId
        } catch {
            logger.error("Error fetching original sender: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Cleanup
    private func scheduleCleanup() {
        let interval = DuplicateDetectionConfig.cleanupInterval
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + interval) { [weak self] in
            Task {
                await self?.cleanup()
                self?.scheduleCleanup()
            }
        }
    }

    private func cleanup() async {
        let cutoff = Date().addingTimeInterval(-DuplicateDetectionConfig.retentionPeriod)
        do {
            let deleted = try await dbPool.write { db in
                try LocalImageSignature
                    .filter(Column("timestamp") < cutoff)
                    .filter(Column("isBlocked") == false)
                    .deleteAll(db)
            }
            logger.info("Cleanup removed \(deleted) unblocked signatures older than \(cutoff)")
        } catch {
            logger.error("Cleanup failed: \(error.localizedDescription)")
        }
    }

    /// Diagnostics string
    func diagnostics() async -> String {
        var total = -1, blocked = -1
        do {
            total = try await dbPool.read { db in try LocalImageSignature.fetchCount(db) }
            blocked = try await dbPool.read { db in try LocalImageSignature.filter(Column("isBlocked")==true).fetchCount(db) }
        } catch {
            logger.error("Diagnostics error: \(error.localizedDescription)")
        }
        return "LocalSignatures: total=\(total), blocked=\(blocked)"
    }
}

fileprivate struct DuplicateDetectionConfig {
    static let retentionPeriod: TimeInterval = 7 * 24 * 3600   // 7 days
    static let cleanupInterval: TimeInterval = 24 * 3600       // daily
}

//  AttachmentDownloadRetryRunner.swift
//  Signal – builds with GRDB 6.x & Swift Concurrency
//
//  SPDX‑License‑Identifier: AGPL‑3.0‑only

import Foundation
import GRDB
import SignalServiceKit
import Logging

/// Periodically checks *AttachmentDownloadQueue* for rows that were blocked because the
/// attachment’s hash lives in `GlobalSignatureService`. Once the hash disappears the
/// record is re‑queued so the normal `AttachmentDownloadManager` can finish it.
public final class AttachmentDownloadRetryRunner {

    // MARK: Facade

    private let db: SDSDatabaseStorage
    private let runner: Runner
    private let dbObserver: DownloadTableObserver
    private let logger = Logger(label: "org.signal.AttachmentDownloadRetryRunner")

    init(
        attachmentDownloadManager: AttachmentDownloadManager,
        attachmentDownloadStore: AttachmentDownloadStore,
        db: SDSDatabaseStorage
    ) {
        self.db = db
        self.runner = Runner(
            attachmentDownloadManager: attachmentDownloadManager,
            attachmentDownloadStore: attachmentDownloadStore,
            db: db
        )
        self.dbObserver = DownloadTableObserver(runner: runner)
    }

    /// Shared instance – wired up from `DependenciesBridge`.
    public static let shared = AttachmentDownloadRetryRunner(
        attachmentDownloadManager: DependenciesBridge.shared.attachmentDownloadManager,
        attachmentDownloadStore: DependenciesBridge.shared.attachmentDownloadStore,
        db: SSKEnvironment.shared.databaseStorageRef
    )

    /// Start DB observation and kick the retry loop once.
    public func beginObserving() {
        logger.info("Starting observation for attachment download retries.")
        db.grdbStorage.pool.add(transactionObserver: dbObserver)

        Task { [weak runner] in await runner?.runIfNotRunning() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterForeground),
            name: .OWSApplicationWillEnterForeground,
            object: nil
        )
    }

    @objc private func didEnterForeground() {
        logger.info("App entered foreground – nudging download manager and retry loop.")
        runner.attachmentDownloadManager.beginDownloadingIfNecessary()
        Task { [weak runner] in await runner?.runIfNotRunning() }
    }

    // MARK: ––– Retry actor

    private actor Runner {
        // Dependencies (non‑isolated for cheap access from anywhere)
        nonisolated let attachmentDownloadManager: AttachmentDownloadManager
        nonisolated let attachmentDownloadStore: AttachmentDownloadStore
        nonisolated let db: SDSDatabaseStorage
        nonisolated let signatureService = GlobalSignatureService.shared
        nonisolated let logger = Logger(label: "org.signal.AttachmentDownloadRetryRunner.Runner")

        // Back‑off config
        private let initialRetryDelay: TimeInterval = 60 * 5      // 5 min
        private let maxRetryDelay:     TimeInterval = 60 * 60 * 24 // 24 h
        private let multiplier:        Double       = 2.0

        // State (actor‑isolated)
        private var isRunning = false
        private var worker: Task<Void, Never>?

        init(
            attachmentDownloadManager: AttachmentDownloadManager,
            attachmentDownloadStore: AttachmentDownloadStore,
            db: SDSDatabaseStorage
        ) {
            self.attachmentDownloadManager = attachmentDownloadManager
            self.attachmentDownloadStore  = attachmentDownloadStore
            self.db                       = db
        }

        /// Entry point – safe from any thread.
        func runIfNotRunning() {
            guard !isRunning else { return }
            isRunning = true

            worker?.cancel()
            worker = Task { [weak self] in
                guard let self else { return }
                await self.loop()
            }
        }

        // ––– main loop
        private func loop() async {
            defer { isRunning = false; worker = nil }

            while !Task.isCancelled {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
                var nextRetryMs: Int64?

                do {
                    // 1) pull candidates
                    let store = self.attachmentDownloadStore  // capture non‑isolated ref
                    let candidates = try await self.db.asyncRead { db in
                        try store.fetchRetryableDownloads(beforeOrAt: nowMs, db: db)
                    }

                    if !candidates.isEmpty {
                        logger.info("Evaluating \(candidates.count) queued record(s).")
                    }

                    var changed = false

                    for record in candidates {
                        guard let id = record.id else { continue }

                        // Fetch the attachment’s aHash via a raw SQL query to avoid relying on
                        // `Attachment` extensions that may not exist in every build.
                        let aHash: String? = try await self.db.asyncRead { db in
                            try String.fetchOne(db, sql: "SELECT aHashString FROM Attachment WHERE id = ?", arguments: [record.attachmentId])
                        }
                        guard let aHash else { continue }

                        let blocked = await signatureService.contains(aHash)

                        if blocked {
                            let nextDelay = nextDelaySeconds(forAttempt: Int(record.retryAttempts))
                            let retryAt   = nowMs + Int64(nextDelay * 1_000)

                            logger.info("hash \(aHash.prefix(8)) still blocked → retry in \(Int(nextDelay)) s")

                            try await self.db.asyncWrite { db in
                                try store.updateRetryAttempt(
                                    id: id,
                                    newTimestamp: retryAt,
                                    newAttemptCount: Int(record.retryAttempts) + 1,
                                    db: db
                                )
                            }
                            changed = true
                        } else {
                            logger.info("hash \(aHash.prefix(8)) cleared – marking ready.")
                            try await self.db.asyncWrite { db in
                                try store.markReadyForDownload(id: id, db: db)
                            }
                            changed = true
                        }
                    }

                    if changed {
                        attachmentDownloadManager.beginDownloadingIfNecessary()
                    }

                    // ask store for the earliest next retry
                    nextRetryMs = try await self.db.asyncRead { db in
                        try store.nextRetryTimestamp(db: db).map { Int64($0) }
                    }
                } catch {
                    logger.error("Retry loop error: \(error)")
                    nextRetryMs = nowMs + Int64(initialRetryDelay * 1_000)
                }

                // Decide sleep duration
                guard let wake = nextRetryMs else { break }
                let sleepMs = max(1_000, wake - nowMs)

                do {
                    try await Task.sleep(nanoseconds: UInt64(sleepMs) * 1_000_000)
                } catch {
                    break // cancelled
                }
            }
        }

        private func nextDelaySeconds(forAttempt attempt: Int) -> TimeInterval {
            let base   = initialRetryDelay * pow(multiplier, Double(attempt))
            let capped = min(base, maxRetryDelay)
            return max(1, capped * Double.random(in: 0.9 ... 1.1))
        }
    }

    // MARK: ––– GRDB Observer

        private class DownloadTableObserver: TransactionObserver {
        private weak var runner: Runner?
        private var shouldKick = false
        private let logger = Logger(label: "org.signal.AttachmentDownloadRetryRunner.Observer")

        init(runner: Runner) { self.runner = runner }

        // GRDB 6.x – the required signature uses stand‑alone `DatabaseEventKind`
        func observes(eventsOfKind kind: DatabaseEventKind) -> Bool {
            switch kind {
            case .insert(let table):
                return table == QueuedAttachmentDownloadRecord.databaseTableName
            case .update(let table, let columns):
                return table == QueuedAttachmentDownloadRecord.databaseTableName &&
                       columns.contains(QueuedAttachmentDownloadRecord.CodingKeys.minRetryTimestamp.rawValue)
            case .delete:
                return false
            }
        }

        func databaseWillChange(with event: DatabaseEvent) {
            if event.tableName == QueuedAttachmentDownloadRecord.databaseTableName {
                shouldKick = true }
        }
        func databaseDidChange(with event: DatabaseEvent) { /* unused */ }
        func databaseWillCommit(_ db: Database) throws { }

        func databaseDidCommit(_ db: Database) {
            guard shouldKick else { return }
            shouldKick = false
            Task { [weak runner] in await runner?.runIfNotRunning() }
        }
        func databaseDidRollback(_ db: Database) { shouldKick = false }
    }
}

// MARK: ––– Async helpers on SDSDatabaseStorage

private extension SDSDatabaseStorage {
    func asyncRead<T>(_ body: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            do {
                let value = try grdbStorage.pool.read { db in try body(db) }
                cont.resume(returning: value)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    func asyncWrite<T>(_ body: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            do {
                let value = try grdbStorage.pool.write { db in try body(db) }
                cont.resume(returning: value)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

// MARK: ––– Protocol stubs (implement in your store)

extension AttachmentDownloadStore {
    func fetchRetryableDownloads(beforeOrAt ts: Int64, db: Database) throws -> [QueuedAttachmentDownloadRecord] {
        fatalError("Implement in concrete store")
    }
    func updateRetryAttempt(id: Int64, newTimestamp: Int64, newAttemptCount: Int, db: Database) throws {
        fatalError("Implement in concrete store")
    }
    func markReadyForDownload(id: Int64, db: Database) throws {
        fatalError("Implement in concrete store")
    }
    func nextRetryTimestamp(db: Database) throws -> UInt64? {
        fatalError("Implement in concrete store")
    }
}

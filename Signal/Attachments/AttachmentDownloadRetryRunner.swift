//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
public import SignalServiceKit
import Logging

public class AttachmentDownloadRetryRunner {

    private let db: SDSDatabaseStorage
    private let runner: Runner
    private let dbObserver: DownloadTableObserver
    private let logger = Logger(label: "org.signal.AttachmentDownloadRetryRunner")

    public init(
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

    public static let shared = AttachmentDownloadRetryRunner(
        attachmentDownloadManager: DependenciesBridge.shared.attachmentDownloadManager,
        attachmentDownloadStore: DependenciesBridge.shared.attachmentDownloadStore,
        db: SSKEnvironment.shared.databaseStorageRef
    )

    public func beginObserving() {
        logger.info("Starting observation for attachment download retries.")
        db.grdbStorage.pool.add(transactionObserver: dbObserver)
        Task { [weak runner] in
            await runner?.runIfNotRunning()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterForeground),
            name: .OWSApplicationWillEnterForeground,
            object: nil
        )
    }

    @objc
    private func didEnterForeground() {
        logger.info("App entered foreground, checking for attachment retries.")
        Task { [weak runner] in
            // Trigger any ready-to-go downloads; this method exits early and cheaply
            // if there is nothing to download.
            self.runner?.attachmentDownloadManager.beginDownloadingIfNecessary()
            // Check for downloads with retry timers and wait for those timers.
            await runner?.runIfNotRunning()
        }
    }

    private actor Runner {
        nonisolated let attachmentDownloadManager: AttachmentDownloadManager
        nonisolated let attachmentDownloadStore: AttachmentDownloadStore
        nonisolated let db: SDSDatabaseStorage
        nonisolated let signatureService = GlobalSignatureService.shared
        nonisolated let logger = Logger(label: "org.signal.AttachmentDownloadRetryRunner.Runner")

        // Configuration for exponential backoff
        private let initialRetryDelaySeconds: TimeInterval = 60 * 5 // 5 minutes
        private let maxRetryDelaySeconds: TimeInterval = 60 * 60 * 24 // 24 hours
        private let backoffMultiplier: Double = 2.0

        init(
            attachmentDownloadManager: AttachmentDownloadManager,
            attachmentDownloadStore: AttachmentDownloadStore,
            db: SDSDatabaseStorage
        ) {
            self.attachmentDownloadManager = attachmentDownloadManager
            self.attachmentDownloadStore = attachmentDownloadStore
            self.db = db
        }

        private var isRunning = false
        private var retryCheckTask: Task<Void, Never>?

        fileprivate func runIfNotRunning() {
            guard !isRunning else {
                logger.debug("Runner is already running.")
                return
            }
            logger.info("Starting runner task.")
            isRunning = true
            // Cancel any previous task before starting a new one
            retryCheckTask?.cancel()
            retryCheckTask = Task { [weak self] in
                await self?.runLoop()
            }
        }

        private func runLoop() async {
            // Ensure the loop stops if the task is cancelled
            while !Task.isCancelled && isRunning {
                let nowMs = Date().ows_millisecondsSince1970
                var nextRetryTimestamp: Int64? = nil

                do {
                    logger.debug("Running check for retryable attachments.")
                    // Fetch attachments that failed due to hash blocking and are due for retry
                    let retryableDownloads = try await db.awaitableRead { tx -> [QueuedAttachmentDownloadRecord] in
                        try self.attachmentDownloadStore.fetchRetryableDownloads(tx: tx, beforeOrAt: nowMs)
                    }

                    if !retryableDownloads.isEmpty {
                        logger.info("Found \(retryableDownloads.count) attachments to check for retry.")
                    } else {
                         logger.debug("No retryable attachments found at this time.")
                    }

                    var madeChanges = false
                    for record in retryableDownloads {
                        guard let aHash = record.aHash else {
                            logger.warning("Retryable record \(record.attachmentPointerId) found without a hash. Skipping.")
                            continue
                        }

                        logger.info("Checking hash \(aHash.prefix(8)) for record \(record.attachmentPointerId)")
                        let isStillBlocked = await signatureService.contains(aHash)

                        if isStillBlocked {
                            // Hash is still blocked, calculate next retry time
                            let nextDelay = calculateNextRetryDelay(currentAttempt: record.retryAttempt)
                            let retryTs = nowMs + Int64(nextDelay * 1000) // Convert seconds to milliseconds
                            logger.info("Hash \(aHash.prefix(8)) still blocked for record \(record.attachmentPointerId). Scheduling next retry at \(Date(ows_millisecondsSince1970: retryTs)). Attempt \(record.retryAttempt + 1).")
                            try await db.awaitableWrite { tx in
                                try self.attachmentDownloadStore.updateRetryAttempt(
                                    id: record.id,
                                    newTimestamp: retryTs,
                                    newAttemptCount: record.retryAttempt + 1,
                                    tx: tx
                                )
                            }
                            madeChanges = true
                        } else {
                            // Hash is no longer blocked, mark as downloadable
                            logger.info("Hash \(aHash.prefix(8)) NO LONGER BLOCKED for record \(record.attachmentPointerId). Marking as downloadable.")
                            try await db.awaitableWrite { tx in
                                // Reset retry state and make it downloadable
                                try self.attachmentDownloadStore.markAsDownloadable(id: record.id, tx: tx)
                            }
                            madeChanges = true
                        }
                    } // end for loop

                    if madeChanges {
                       // If we made any record downloadable, trigger the download manager
                       logger.info("Triggering download manager after processing retries.")
                       attachmentDownloadManager.beginDownloadingIfNecessary()
                    }

                    // Find the next earliest retry timestamp from the DB
                    nextRetryTimestamp = try await db.awaitableRead { tx in
                        try self.attachmentDownloadStore.nextRetryTimestamp(tx: tx)
                    }

                } catch {
                    logger.error("Error during retry check loop: \(error.localizedDescription)")
                     // In case of error, back off before retrying the whole loop
                     nextRetryTimestamp = nowMs + Int64(initialRetryDelaySeconds * 1000)
                }

                // --- Sleep until the next check ---
                let sleepDurationMs: Int64
                if let nextTs = nextRetryTimestamp, nextTs > nowMs {
                     sleepDurationMs = nextTs - nowMs
                     logger.debug("Next check scheduled for \(Date(ows_millisecondsSince1970: nextTs)) (\(sleepDurationMs / 1000) seconds). Sleeping.")
                } else if nextRetryTimestamp != nil {
                     // Next timestamp is in the past or now, run again immediately (with small delay)
                     sleepDurationMs = 1000 // 1 second delay to prevent tight loop
                     logger.debug("Next check timestamp is in the past/now. Running again soon.")
                } else {
                     // No more retryable downloads scheduled, stop the runner.
                     logger.info("No further retry timestamps found. Stopping runner task.")
                     self.isRunning = false
                     break // Exit the while loop
                }

                do {
                     try await Task.sleep(nanoseconds: UInt64(max(1000, sleepDurationMs)) * NSEC_PER_MSEC) // Ensure minimum sleep
                } catch {
                     logger.info("Task sleep interrupted. Stopping runner task.")
                     self.isRunning = false
                     break // Exit loop if sleep is cancelled
                }
            } // end while loop

            // Cleanup if the loop finishes naturally or is cancelled
            self.isRunning = false
            self.retryCheckTask = nil
            logger.info("Runner task finished.")
        }

        /// Calculates the next delay using exponential backoff with jitter.
        private func calculateNextRetryDelay(currentAttempt: Int) -> TimeInterval {
             let attemptFactor = pow(backoffMultiplier, Double(currentAttempt))
             let baseDelay = initialRetryDelaySeconds * attemptFactor
             let cappedDelay = min(baseDelay, maxRetryDelaySeconds)
             // Add ±10% jitter
             let jitter = cappedDelay * Double.random(in: -0.1...0.1)
             return max(1.0, cappedDelay + jitter) // Ensure minimum 1 second delay
        }

    } // end Runner actor

    // MARK: - Observation

    private class DownloadTableObserver: TransactionObserver {

        private weak var runner: Runner? // Use weak reference to avoid potential retain cycles
        nonisolated let logger = Logger(label: "org.signal.AttachmentDownloadRetryRunner.Observer")

        init(runner: Runner) {
            self.runner = runner
        }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            // Observe updates to the retry timestamp or hash field, as these might schedule
            // the runner sooner or indicate a new item needs retry scheduling.
            // Also observe inserts which *might* eventually become retryable.
            switch eventKind {
            case let .update(tableName, columnNames):
                return
                    tableName == QueuedAttachmentDownloadRecord.databaseTableName
                    && (columnNames.contains(QueuedAttachmentDownloadRecord.CodingKeys.minRetryTimestamp.rawValue)
                        || columnNames.contains(QueuedAttachmentDownloadRecord.CodingKeys.aHash.rawValue)) // Assuming aHash is a coding key
            case let .insert(tableName):
                 // Observe inserts to the table in case a new item fails immediately and needs retry.
                 return tableName == QueuedAttachmentDownloadRecord.databaseTableName
            case .delete:
                // Deletes shouldn't affect the need to run the retry logic.
                return false
            }
        }


        private var shouldRunOnNextCommit = false

        // Using databaseWillChange might be slightly more robust if multiple events occur in one transaction
        func databaseWillChange(with event: DatabaseEvent) {
             // Check if the event kind is one we observe
             if observes(eventsOfKind: event.kind) {
                  shouldRunOnNextCommit = true
                  logger.trace("Observed relevant change, flag set for commit: \(event.tableName):\(event.rowID)")
             }
        }

        func databaseDidChange(with event: DatabaseEvent) {
             /* Now handled in databaseWillChange */
             logger.trace("Database did change: \(event.tableName):\(event.rowID)")
        }

        func databaseDidCommit(_ db: GRDB.Database) {
            guard shouldRunOnNextCommit else {
                logger.trace("Database committed, but no relevant changes observed.")
                return
            }
            shouldRunOnNextCommit = false

            logger.info("Relevant change committed, triggering retry runner.")
            // When we get a matching event, run the next job _after_ committing.
            Task { [weak runner] in
                runner?.runIfNotRunning()
            }
        }

        func databaseDidRollback(_ db: GRDB.Database) {
             // Reset flag on rollback
              shouldRunOnNextCommit = false
              logger.trace("Database rolled back, reset trigger flag.")
        }
    }
}

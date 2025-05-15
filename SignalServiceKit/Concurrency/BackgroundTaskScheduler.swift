//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// A scheduler for background tasks that provides priority-based queueing,
/// cooperative yielding, intelligent batching, and deadline-based execution.
public class BackgroundTaskScheduler {
    
    // MARK: - Types
    
    public enum TaskPriority: Int, Comparable {
        case high = 0
        case default = 1
        case low = 2
        case background = 3
        
        public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
    
    public struct TaskDescriptor: Identifiable {
        public let id: UUID
        let priority: TaskPriority
        let category: String
        let creationDate: Date
        let deadline: Date?
        let operation: @Sendable () async throws -> Void
        
        fileprivate var isCancelled = false
        
        public init(
            id: UUID = UUID(),
            priority: TaskPriority = .default,
            category: String,
            deadline: Date? = nil,
            operation: @escaping @Sendable () async throws -> Void
        ) {
            self.id = id
            self.priority = priority
            self.category = category
            self.creationDate = Date()
            self.deadline = deadline
            self.operation = operation
        }
    }
    
    private enum BatchableTaskGroup: Hashable {
        case byCategory(String)
    }
    
    public struct PerformanceMetrics {
        public private(set) var totalTasksExecuted: Int = 0
        public private(set) var totalExecutionTime: TimeInterval = 0
        public private(set) var averageExecutionTime: TimeInterval = 0
        public private(set) var tasksCompletedSuccessfully: Int = 0
        public private(set) var tasksFailed: Int = 0
        public private(set) var tasksCancelled: Int = 0
        public private(set) var tasksMissedDeadline: Int = 0
        
        mutating func recordTaskExecution(duration: TimeInterval, successful: Bool, cancelled: Bool, missedDeadline: Bool) {
            totalTasksExecuted += 1
            totalExecutionTime += duration
            averageExecutionTime = totalExecutionTime / Double(totalTasksExecuted)
            
            if cancelled {
                tasksCancelled += 1
            } else if successful {
                tasksCompletedSuccessfully += 1
            } else {
                tasksFailed += 1
            }
            
            if missedDeadline {
                tasksMissedDeadline += 1
            }
        }
    }
    
    // MARK: - Properties
    
    private let taskQueueLock = UnfairLock()
    private var taskQueue = [TaskDescriptor]()
    private var runningTasks = [UUID: Task<Void, Error>]()
    private var batchedTasks = [BatchableTaskGroup: [TaskDescriptor]]()
    
    private let concurrentTaskQueue: ConcurrentTaskQueue
    private let maxConcurrentTasks: Int
    
    private var metrics = PerformanceMetrics()
    private let metricsLock = UnfairLock()
    
    private let yieldInterval: UInt64 = 10_000_000 // 10ms in nanoseconds
    private let longRunningTaskThreshold: TimeInterval = 5.0 // 5 seconds
    
    // MARK: - Lifecycle
    
    public init() {
        // Determine optimal thread pool size based on device capabilities
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let defaultMaxConcurrentTasks = max(2, processorCount - 1)
        
        // Adjust for memory constraints
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryThresholdGB: UInt64 = 2 * 1024 * 1024 * 1024 // 2GB
        
        let adjustedMaxTasks: Int
        if physicalMemory < memoryThresholdGB {
            // Low memory device - reduce concurrency
            adjustedMaxTasks = min(defaultMaxConcurrentTasks, 2)
        } else {
            adjustedMaxTasks = defaultMaxConcurrentTasks
        }
        
        self.maxConcurrentTasks = adjustedMaxTasks
        self.concurrentTaskQueue = ConcurrentTaskQueue(concurrentLimit: adjustedMaxTasks)
        
        Logger.info("[BackgroundTaskScheduler] Initialized with max concurrent tasks: \(adjustedMaxTasks)")
    }
    
    // MARK: - Public Methods
    
    /// Schedule a task to be executed by the background scheduler
    @discardableResult
    public func schedule(
        priority: TaskPriority = .default,
        category: String,
        deadline: Date? = nil,
        operation: @escaping @Sendable () async throws -> Void
    ) -> UUID {
        let taskDescriptor = TaskDescriptor(
            priority: priority,
            category: category,
            deadline: deadline,
            operation: operation
        )
        
        taskQueueLock.withLock {
            taskQueue.append(taskDescriptor)
            
            // Sort queue by priority, then by creation date within each priority level
            taskQueue.sort { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                
                // If there's a deadline, prioritize tasks with earlier deadlines
                if let lhsDeadline = lhs.deadline, let rhsDeadline = rhs.deadline {
                    return lhsDeadline < rhsDeadline
                } else if lhs.deadline != nil && rhs.deadline == nil {
                    return true // Prioritize tasks with deadlines
                } else if lhs.deadline == nil && rhs.deadline != nil {
                    return false
                }
                
                return lhs.creationDate < rhs.creationDate
            }
            
            // Check for batch opportunities
            let batchGroup = BatchableTaskGroup.byCategory(category)
            if var batch = batchedTasks[batchGroup] {
                batch.append(taskDescriptor)
                batchedTasks[batchGroup] = batch
            } else {
                batchedTasks[batchGroup] = [taskDescriptor]
            }
        }
        
        // Start processing if needed
        processNextTasks()
        
        return taskDescriptor.id
    }
    
    /// Cancel a previously scheduled task
    public func cancelTask(withId taskId: UUID) {
        var cancelledTask: Task<Void, Error>?
        
        taskQueueLock.withLock {
            // First check if it's in the queue
            if let index = taskQueue.firstIndex(where: { $0.id == taskId }) {
                var task = taskQueue[index]
                task.isCancelled = true
                taskQueue[index] = task
            }
            
            // Then check if it's already running
            cancelledTask = runningTasks[taskId]
        }
        
        // Cancel task if it's already running
        cancelledTask?.cancel()
    }
    
    /// Cancel all tasks in the specified category
    public func cancelAllTasks(inCategory category: String) {
        var cancelledTasks = [Task<Void, Error>]()
        
        taskQueueLock.withLock {
            // Mark all queued tasks in this category as cancelled
            for i in 0..<taskQueue.count where taskQueue[i].category == category {
                var task = taskQueue[i]
                task.isCancelled = true
                taskQueue[i] = task
            }
            
            // Collect tasks to cancel
            for (taskId, task) in runningTasks {
                if let index = taskQueue.firstIndex(where: { $0.id == taskId }),
                   taskQueue[index].category == category {
                    cancelledTasks.append(task)
                }
            }
        }
        
        // Cancel tasks after releasing the lock
        for task in cancelledTasks {
            task.cancel()
        }
    }
    
    /// Get a snapshot of the current performance metrics
    public func getPerformanceMetrics() -> PerformanceMetrics {
        return metricsLock.withLock {
            return metrics
        }
    }
    
    /// Reset performance metrics
    public func resetPerformanceMetrics() {
        metricsLock.withLock {
            metrics = PerformanceMetrics()
        }
    }
    
    // MARK: - Private Methods
    
    private func processNextTasks() {
        taskQueueLock.withLock {
            // Check for expired deadlines
            let now = Date()
            for i in 0..<taskQueue.count {
                if let deadline = taskQueue[i].deadline, deadline < now {
                    // Mark as missed deadline in metrics
                    let taskId = taskQueue[i].id
                    metricsLock.withLock {
                        metrics.recordTaskExecution(
                            duration: 0,
                            successful: false,
                            cancelled: false,
                            missedDeadline: true
                        )
                    }
                    
                    // Remove task from queue
                    taskQueue.remove(at: i)
                    Logger.warn("[BackgroundTaskScheduler] Task \(taskId) removed due to missed deadline")
                }
            }
            
            // Process batches first if possible
            processBatchedTasks()
            
            // If queue is empty, nothing to do
            guard !taskQueue.isEmpty else {
                return
            }
            
            // Start next tasks
            let nextTasks = selectNextTasks()
            for task in nextTasks {
                startTask(task)
            }
        }
    }
    
    private func selectNextTasks() -> [TaskDescriptor] {
        // Get maximum number of tasks that can be processed now
        let runningTaskCount = runningTasks.count
        let tasksToStart = min(maxConcurrentTasks - runningTaskCount, taskQueue.count)
        
        guard tasksToStart > 0 else {
            return []
        }
        
        // Get highest priority tasks
        var result = [TaskDescriptor]()
        for _ in 0..<tasksToStart {
            if let nextTask = taskQueue.first {
                taskQueue.removeFirst()
                result.append(nextTask)
            }
        }
        
        return result
    }
    
    private func processBatchedTasks() {
        // Find batched tasks that meet the threshold for processing as a group
        let batchThreshold = 5 // Minimum batch size to trigger batch processing
        
        for (batchKey, tasks) in batchedTasks {
            if tasks.count >= batchThreshold {
                let batchedOperation = createBatchedOperation(for: tasks)
                
                // Create a combined task descriptor with highest priority from batch
                let highestPriority = tasks.map { $0.priority }.min() ?? .default
                let batchId = UUID()
                let batchDescriptor = TaskDescriptor(
                    id: batchId,
                    priority: highestPriority,
                    category: "batch.\(batchKey)",
                    operation: batchedOperation
                )
                
                // Remove individual tasks and schedule the batch instead
                for task in tasks {
                    if let index = taskQueue.firstIndex(where: { $0.id == task.id }) {
                        taskQueue.remove(at: index)
                    }
                }
                
                // Add batch at the front of its priority level
                if let insertIndex = taskQueue.firstIndex(where: { $0.priority > highestPriority }) {
                    taskQueue.insert(batchDescriptor, at: insertIndex)
                } else {
                    taskQueue.append(batchDescriptor)
                }
                
                // Clear the batch
                batchedTasks[batchKey] = []
            }
        }
    }
    
    private func createBatchedOperation(for tasks: [TaskDescriptor]) -> @Sendable () async throws -> Void {
        return { [weak self] in
            // Create a task group to run all operations concurrently
            try await withThrowingTaskGroup(of: Void.self) { group in
                for task in tasks {
                    if Task.isCancelled {
                        break
                    }
                    
                    group.addTask {
                        try await task.operation()
                    }
                }
                
                // Wait for all tasks to complete
                try await group.waitForAll()
            }
            
            // Update metrics for all tasks in the batch
            self?.metricsLock.withLock {
                for _ in tasks {
                    self?.metrics.recordTaskExecution(
                        duration: 0, // We don't track individual durations in batches
                        successful: true,
                        cancelled: false,
                        missedDeadline: false
                    )
                }
            }
        }
    }
    
    private func startTask(_ descriptor: TaskDescriptor) {
        // Don't start cancelled tasks
        if descriptor.isCancelled {
            metricsLock.withLock {
                metrics.recordTaskExecution(
                    duration: 0,
                    successful: false,
                    cancelled: true,
                    missedDeadline: false
                )
            }
            return
        }
        
        // Create task and keep track of it
        let newTask = Task {
            do {
                // Run the task with cooperative yielding using the concurrent task queue
                let startTime = Date()
                
                try await concurrentTaskQueue.run {
                    // Check for deadline if one is specified
                    if let deadline = descriptor.deadline {
                        try await withCooperativeTimeout(seconds: deadline.timeIntervalSinceNow) {
                            try await executeWithYielding(descriptor.operation)
                        }
                    } else {
                        try await executeWithYielding(descriptor.operation)
                    }
                }
                
                // Record successful execution
                let executionDuration = Date().timeIntervalSince(startTime)
                
                metricsLock.withLock {
                    metrics.recordTaskExecution(
                        duration: executionDuration,
                        successful: true,
                        cancelled: false,
                        missedDeadline: false
                    )
                }
                
                // Log long-running tasks
                if executionDuration > longRunningTaskThreshold {
                    Logger.warn("[BackgroundTaskScheduler] Task \(descriptor.id) in category \(descriptor.category) took \(executionDuration)s to complete")
                }
            } catch is CancellationError {
                // Task was cancelled
                metricsLock.withLock {
                    metrics.recordTaskExecution(
                        duration: 0,
                        successful: false,
                        cancelled: true,
                        missedDeadline: false
                    )
                }
            } catch is CooperativeTimeoutError {
                // Task exceeded its deadline
                metricsLock.withLock {
                    metrics.recordTaskExecution(
                        duration: 0,
                        successful: false,
                        cancelled: false,
                        missedDeadline: true
                    )
                }
                Logger.error("[BackgroundTaskScheduler] Task \(descriptor.id) in category \(descriptor.category) exceeded deadline")
            } catch {
                // Task failed
                metricsLock.withLock {
                    metrics.recordTaskExecution(
                        duration: 0,
                        successful: false,
                        cancelled: false,
                        missedDeadline: false
                    )
                }
                Logger.error("[BackgroundTaskScheduler] Task \(descriptor.id) in category \(descriptor.category) failed with error: \(error)")
            }
            
            // Clean up task tracking
            taskQueueLock.withLock {
                runningTasks.removeValue(forKey: descriptor.id)
            }
            
            // Process next tasks
            processNextTasks()
        }
        
        taskQueueLock.withLock {
            runningTasks[descriptor.id] = newTask
        }
    }
    
    /// Execute an operation with periodic yielding to prevent blocking the thread
    private func executeWithYielding(_ operation: @Sendable () async throws -> Void) async throws {
        // Create a child task for the operation
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        var yieldCounter: UInt64 = 0
                        let startTime = DispatchTime.now()
                        
                        // Run in a child task that periodically checks if it should yield
                        try await withTaskGroup(of: Void.self) { group in
                            group.addTask {
                                do {
                                    try await operation()
                                } catch {
                                    continuation.resume(throwing: error)
                                    return
                                }
                                continuation.resume()
                            }
                            
                            // Check if we should continue or yield
                            while !Task.isCancelled {
                                // Check only periodically to reduce overhead
                                yieldCounter += 1
                                if yieldCounter % 100 == 0 {
                                    let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                                    
                                    if elapsed > yieldInterval {
                                        // Yield to other tasks
                                        await Task.yield()
                                    }
                                }
                                
                                // Break if the operation task is complete
                                if group.isEmpty {
                                    break
                                }
                                
                                try await Task.sleep(nanoseconds: 100_000) // 0.1ms sleep
                            }
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            // Propagate cancellation
        })
    }
}
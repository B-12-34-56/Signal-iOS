import XCTest
import SignalServiceKit
import AWSCore
import AWSDynamoDB
import AWSS3
@testable import DuplicateContentDetection
import Logging

class BatchImportJobTrackerTests: XCTestCase {
    // MARK: - Properties
    
    private var jobTracker: BatchImportJobTracker!
    
    // MARK: - Setup
    
    override func setUp() async throws {
        try await super.setUp()
        jobTracker = BatchImportJobTracker(maxConcurrentJobs: 2)
    }
    
    // MARK: - Tests
    
    func testCreateAndProcessJob() async throws {
        // Setup
        let items = ["item1", "item2", "item3"]
        
        // Execute
        let job = try await jobTracker.createJob(
            service: "S3",
            operation: "PutObject",
            items: items
        )
        
        // Wait for job to complete
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Verify
        let status = jobTracker.getJobStatus(jobId: job.id)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.status, .completed)
        XCTAssertEqual(status?.progress, 1.0)
    }
    
    func testMultipleJobs() async throws {
        // Setup
        let items1 = ["item1", "item2"]
        let items2 = ["item3", "item4"]
        let items3 = ["item5", "item6"]
        
        // Execute
        let job1 = try await jobTracker.createJob(
            service: "S3",
            operation: "PutObject",
            items: items1
        )
        let job2 = try await jobTracker.createJob(
            service: "DynamoDB",
            operation: "PutItem",
            items: items2
        )
        let job3 = try await jobTracker.createJob(
            service: "Lambda",
            operation: "Invoke",
            items: items3
        )
        
        // Wait for jobs to complete
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Verify
        let status1 = jobTracker.getJobStatus(jobId: job1.id)
        let status2 = jobTracker.getJobStatus(jobId: job2.id)
        let status3 = jobTracker.getJobStatus(jobId: job3.id)
        
        XCTAssertEqual(status1?.status, .completed)
        XCTAssertEqual(status2?.status, .completed)
        XCTAssertEqual(status3?.status, .completed)
    }
    
    func testJobCancellation() async throws {
        // Setup
        let items = ["item1", "item2", "item3"]
        
        // Execute
        let job = try await jobTracker.createJob(
            service: "S3",
            operation: "PutObject",
            items: items
        )
        
        // Cancel job
        try await jobTracker.cancelJob(jobId: job.id)
        
        // Verify
        let status = jobTracker.getJobStatus(jobId: job.id)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.status, .cancelled)
    }
    
    func testActiveJobs() async throws {
        // Setup
        let items1 = ["item1", "item2"]
        let items2 = ["item3", "item4"]
        
        // Execute
        let job1 = try await jobTracker.createJob(
            service: "S3",
            operation: "PutObject",
            items: items1
        )
        let job2 = try await jobTracker.createJob(
            service: "DynamoDB",
            operation: "PutItem",
            items: items2
        )
        
        // Get active jobs
        let activeJobs = jobTracker.getActiveJobs()
        
        // Verify
        XCTAssertEqual(activeJobs.count, 2)
        XCTAssertTrue(activeJobs.contains { $0.id == job1.id })
        XCTAssertTrue(activeJobs.contains { $0.id == job2.id })
    }
    
    func testJobProgress() async throws {
        // Setup
        let items = ["item1", "item2", "item3", "item4", "item5"]
        
        // Execute
        let job = try await jobTracker.createJob(
            service: "S3",
            operation: "PutObject",
            items: items
        )
        
        // Wait for partial completion
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Verify progress
        let status = jobTracker.getJobStatus(jobId: job.id)
        XCTAssertNotNil(status)
        XCTAssertGreaterThan(status?.progress ?? 0, 0)
        XCTAssertLessThan(status?.progress ?? 1, 1)
    }
    
    func testJobErrorHandling() async throws {
        // Setup
        let items = ["item1", "item2", "item3"]
        let testError = NSError(domain: "Test", code: -1)
        
        // Execute
        let job = try await jobTracker.createJob(
            service: "S3",
            operation: "PutObject",
            items: items,
            error: testError
        )
        
        // Wait for job to complete
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Verify
        let status = jobTracker.getJobStatus(jobId: job.id)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.status, .failed)
        XCTAssertNotNil(status?.error)
    }
    
    func testConcurrentJobLimit() async throws {
        // Setup
        let items = ["item1", "item2"]
        jobTracker = BatchImportJobTracker(maxConcurrentJobs: 1)
        
        // Execute
        let job1 = try await jobTracker.createJob(
            service: "S3",
            operation: "PutObject",
            items: items
        )
        let job2 = try await jobTracker.createJob(
            service: "DynamoDB",
            operation: "PutItem",
            items: items
        )
        
        // Wait for jobs to complete
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Verify
        let status1 = jobTracker.getJobStatus(jobId: job1.id)
        let status2 = jobTracker.getJobStatus(jobId: job2.id)
        
        XCTAssertEqual(status1?.status, .completed)
        XCTAssertEqual(status2?.status, .completed)
    }
} 
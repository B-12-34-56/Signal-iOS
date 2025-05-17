import XCTest
import SignalServiceKit
import AWSCore
import AWSDynamoDB
import AWSS3
@testable import DuplicateContentDetection
import Logging

class AWSServiceTests: XCTestCase {
    // MARK: - Properties
    
    private var connectionManager: AWSConnectionManager!
    private var credentialCache: AWSCredentialCache!
    private var performanceMetrics: AWSPerformanceMetrics!
    private var batchTracker: BatchImportJobTracker!
    
    // MARK: - Setup
    
    override func setUp() async throws {
        try await super.setUp()
        
        connectionManager = AWSConnectionManager()
        credentialCache = AWSCredentialCache()
        performanceMetrics = AWSPerformanceMetrics()
        batchTracker = BatchImportJobTracker()
    }
    
    // MARK: - Tests
    
    func testConnectionManagerRetry() async throws {
        var attemptCount = 0
        let maxAttempts = 3
        
        do {
            _ = try await connectionManager.executeWithRetry(
                {
                    attemptCount += 1
                    if attemptCount < maxAttempts {
                        throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test error"])
                    }
                    return "Success"
                },
                serviceName: "TestService",
                operationName: "TestOperation"
            )
            
            XCTAssertEqual(attemptCount, maxAttempts, "Should have retried \(maxAttempts) times")
        } catch {
            XCTFail("Should have succeeded after retries")
        }
    }
    
    func testCredentialCache() throws {
        let credentials = AWSCredentials(
            accessKey: "test-access-key",
            secretKey: "test-secret-key",
            sessionToken: "test-session-token",
            expiration: Date().addingTimeInterval(3600)
        )
        
        // Store credentials
        try credentialCache.storeCredentials(credentials, forService: "TestService")
        
        // Retrieve credentials
        let retrieved = try credentialCache.getCredentials(forService: "TestService")
        XCTAssertNotNil(retrieved, "Should retrieve stored credentials")
        XCTAssertEqual(retrieved?.accessKey, credentials.accessKey)
        XCTAssertEqual(retrieved?.secretKey, credentials.secretKey)
        
        // Remove credentials
        try credentialCache.removeCredentials(forService: "TestService")
        XCTAssertNil(try credentialCache.getCredentials(forService: "TestService"), "Should not retrieve removed credentials")
    }
    
    func testPerformanceMetrics() {
        // Record some metrics
        performanceMetrics.recordMetric(
            service: "S3",
            operation: "PutObject",
            duration: 0.5,
            success: true,
            requestSize: 1024,
            responseSize: 512
        )
        
        performanceMetrics.recordMetric(
            service: "S3",
            operation: "GetObject",
            duration: 1.5,
            success: false,
            error: NSError(domain: "Test", code: -1),
            requestSize: 512,
            responseSize: 0
        )
        
        // Check stats
        let stats = performanceMetrics.getServiceStats("S3")
        XCTAssertEqual(stats.totalRequests, 2)
        XCTAssertEqual(stats.successfulRequests, 1)
        XCTAssertEqual(stats.failedRequests, 1)
        XCTAssertEqual(stats.totalBytesSent, 1536)
        XCTAssertEqual(stats.totalBytesReceived, 512)
    }
    
    func testBatchImportJobTracker() async throws {
        // Create test items
        let items = (1...1000).map { "Item \($0)" }
        
        // Create job
        let jobId = batchTracker.createJob(
            service: "DynamoDB",
            operation: "BatchWriteItem",
            items: items
        )
        
        // Wait for job to start
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Check initial status
        let initialStatus = batchTracker.getJobStatus(jobId)
        XCTAssertNotNil(initialStatus)
        XCTAssertEqual(initialStatus?.status, .inProgress)
        XCTAssertGreaterThan(initialStatus?.progress ?? 0, 0)
        
        // Wait for job to complete
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Check final status
        let finalStatus = batchTracker.getJobStatus(jobId)
        XCTAssertNotNil(finalStatus)
        XCTAssertEqual(finalStatus?.status, .completed)
        XCTAssertEqual(finalStatus?.progress, 1.0)
    }
    
    func testBatchImportJobCancellation() async throws {
        // Create test items
        let items = (1...1000).map { "Item \($0)" }
        
        // Create job
        let jobId = batchTracker.createJob(
            service: "DynamoDB",
            operation: "BatchWriteItem",
            items: items
        )
        
        // Wait for job to start
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Cancel job
        batchTracker.cancelJob(jobId)
        
        // Check status
        let status = batchTracker.getJobStatus(jobId)
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.status, .cancelled)
    }
    
    func testConcurrentJobs() async throws {
        // Create multiple jobs
        let jobIds = (1...5).map { i in
            batchTracker.createJob(
                service: "DynamoDB",
                operation: "BatchWriteItem",
                items: (1...100).map { "Job \(i) Item \($0)" }
            )
        }
        
        // Wait for jobs to start
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Check active jobs
        let activeJobs = batchTracker.getActiveJobs()
        XCTAssertLessThanOrEqual(activeJobs.count, 3, "Should not exceed max concurrent jobs")
        
        // Wait for jobs to complete
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Check final statuses
        for jobId in jobIds {
            let status = batchTracker.getJobStatus(jobId)
            XCTAssertNotNil(status)
            XCTAssertEqual(status?.status, .completed)
            XCTAssertEqual(status?.progress, 1.0)
        }
    }
} 
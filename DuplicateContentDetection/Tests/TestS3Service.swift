//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import AWSCore
import AWSS3
import CryptoKit
@testable import Signal

/// Tests for the S3Service class to validate AWS S3 interaction functionality
class S3ServiceTests: XCTestCase {
    
    // MARK: - Properties
    
    private var mockClient: AWSS3MockClient!
    private var service: TestableSEService!
    private let defaultRetryCount = 3
    private let testBucketName = "signal-content-attachments"
    
    // Test data for uploads and downloads
    private let smallData = Data("small test content".utf8)
    private let mediumData = Data(repeating: 0xAB, count: 1024) // 1KB
    private let largeData = Data(repeating: 0xCD, count: 1024 * 1024) // 1MB
    
    // MARK: - Test Lifecycle
    
    override func setUp() async throws {
        super.setUp()
        mockClient = AWSS3MockClient.shared
        mockClient.reset()
        service = TestableSEService(mockClient: mockClient)
    }
    
    override func tearDown() async throws {
        mockClient = nil
        service = nil
        super.tearDown()
    }
    
    // MARK: - File Upload Tests
    
    func testUploadFile_SuccessfulUpload() async {
        // Arrange
        let testKey = "test/file.txt"
        let testContentType = "text/plain"
        
        // Act
        let result = await service.uploadFile(data: smallData, key: testKey, contentType: testContentType)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .putObject), 1)
        
        let uploadOperation = mockClient.getOperationLog().first { $0.type == .putObject }
        XCTAssertEqual(uploadOperation?.key, testKey)
        XCTAssertEqual(uploadOperation?.bucket, testBucketName)
        XCTAssertEqual(uploadOperation?.contentType, testContentType)
    }
    
    func testUploadFile_ContentTypeAutoDetection() async {
        // Arrange
        let testKey = "test/image.jpg"
        let imageData = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0, count: 100) // JPEG signature
        
        // Act
        let result = await service.uploadFile(data: imageData, key: testKey)
        
        // Assert
        XCTAssertTrue(result)
        let uploadOperation = mockClient.getOperationLog().first { $0.type == .putObject }
        XCTAssertEqual(uploadOperation?.contentType, "image/jpeg")
    }
    
    func testUploadFile_WithThrottlingError_Retries() async {
        // Arrange
        let testKey = "test/retry_file.txt"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSS3ErrorDomain,
            code: AWSS3ErrorType.throttling.rawValue,
            userInfo: nil
        ))
        mockClient.setRetrySuccessAfter(attempts: 2)
        
        // Act
        let result = await service.uploadFile(data: smallData, key: testKey)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .putObject), 2)
    }
    
    func testUploadFile_WithPersistentError_Fails() async {
        // Arrange
        let testKey = "test/error_file.txt"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSS3ErrorDomain,
            code: AWSS3ErrorType.accessDenied.rawValue,
            userInfo: nil
        ))
        
        // Act
        let result = await service.uploadFile(data: smallData, key: testKey)
        
        // Assert
        XCTAssertFalse(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .putObject), defaultRetryCount)
    }
    
    func testUploadFile_WithLargeFile() async {
        // Arrange
        let testKey = "test/large_file.bin"
        
        // Act
        let result = await service.uploadFile(data: largeData, key: testKey)
        
        // Assert
        XCTAssertTrue(result)
        let uploadOperation = mockClient.getOperationLog().first { $0.type == .putObject }
        XCTAssertEqual(uploadOperation?.contentLength, largeData.count)
    }
    
    // MARK: - File Download Tests
    
    func testDownloadFile_SuccessfulDownload() async {
        // Arrange
        let testKey = "test/download_file.txt"
        mockClient.addStoredFile(key: testKey, data: smallData)
        
        // Act
        let downloadedData = await service.downloadFile(key: testKey)
        
        // Assert
        XCTAssertNotNil(downloadedData)
        XCTAssertEqual(downloadedData, smallData)
        XCTAssertEqual(mockClient.getOperationCount(type: .getObject), 1)
    }
    
    func testDownloadFile_FileDoesNotExist() async {
        // Arrange
        let testKey = "test/nonexistent_file.txt"
        
        // Act
        let downloadedData = await service.downloadFile(key: testKey)
        
        // Assert
        XCTAssertNil(downloadedData)
    }
    
    func testDownloadFile_NetworkErrorWithRetry() async {
        // Arrange
        let testKey = "test/network_error_file.txt"
        mockClient.addStoredFile(key: testKey, data: mediumData)
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: nil
        ))
        mockClient.setRetrySuccessAfter(attempts: 2)
        
        // Act
        let downloadedData = await service.downloadFile(key: testKey)
        
        // Assert
        XCTAssertNotNil(downloadedData)
        XCTAssertEqual(downloadedData, mediumData)
        XCTAssertEqual(mockClient.getOperationCount(type: .getObject), 2)
    }
    
    // MARK: - File Existence Tests
    
    func testFileExists_ExistingFile_ReturnsTrue() async {
        // Arrange
        let testKey = "test/existing_file.txt"
        mockClient.addStoredFile(key: testKey, data: smallData)
        
        // Act
        let exists = await service.fileExists(key: testKey)
        
        // Assert
        XCTAssertTrue(exists)
        XCTAssertEqual(mockClient.getOperationCount(type: .headObject), 1)
    }
    
    func testFileExists_NonExistentFile_ReturnsFalse() async {
        // Arrange
        let testKey = "test/nonexistent_file.txt"
        
        // Act
        let exists = await service.fileExists(key: testKey)
        
        // Assert
        XCTAssertFalse(exists)
    }
    
    // MARK: - Pre-signed URL Tests
    
    func testGeneratePresignedURL_Success() async {
        // Arrange
        let testKey = "test/url_file.txt"
        let expirationTime: TimeInterval = 3600 // 1 hour
        mockClient.setPresignedURL(URL(string: "https://s3.example.com/\(testKey)?signed=true")!)
        
        // Act
        let url = await service.generatePresignedURL(for: testKey, expiresIn: expirationTime)
        
        // Assert
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains(testKey))
        XCTAssertTrue(url!.absoluteString.contains("signed=true"))
    }
    
    func testGeneratePresignedURL_WithError_ReturnsNil() async {
        // Arrange
        let testKey = "test/url_error_file.txt"
        mockClient.setFailureMode(shouldFail: true, error: NSError(
            domain: AWSS3ErrorDomain,
            code: AWSS3ErrorType.invalidAccessKeyId.rawValue,
            userInfo: nil
        ))
        
        // Act
        let url = await service.generatePresignedURL(for: testKey)
        
        // Assert
        XCTAssertNil(url)
    }
    
    // MARK: - Delete File Tests
    
    func testDeleteFile_ExistingFile_Success() async {
        // Arrange
        let testKey = "test/delete_file.txt"
        mockClient.addStoredFile(key: testKey, data: smallData)
        
        // Act
        let result = await service.deleteFile(key: testKey)
        
        // Assert
        XCTAssertTrue(result)
        XCTAssertEqual(mockClient.getOperationCount(type: .deleteObject), 1)
    }
    
    func testDeleteFile_NonExistentFile_StillReturnsSuccess() async {
        // Arrange
        let testKey = "test/nonexistent_delete_file.txt"
        
        // Act
        let result = await service.deleteFile(key: testKey)
        
        // Assert
        XCTAssertTrue(result)
    }
    
    // MARK: - Unique Key Generation Tests
    
    func testGenerateUniqueKey_Default() {
        // Act
        let key = service.generateUniqueKey()
        
        // Assert
        XCTAssertFalse(key.isEmpty)
        XCTAssertTrue(key.contains("-"))
        XCTAssertFalse(key.contains("/"))
    }
    
    func testGenerateUniqueKey_WithPrefix() {
        // Arrange
        let prefix = "test-folder"
        
        // Act
        let key = service.generateUniqueKey(prefix: prefix)
        
        // Assert
        XCTAssertTrue(key.hasPrefix("\(prefix)/"))
    }
    
    func testGenerateUniqueKey_WithExtension() {
        // Arrange
        let extension = "jpg"
        
        // Act
        let key = service.generateUniqueKey(fileExtension: extension)
        
        // Assert
        XCTAssertTrue(key.hasSuffix(".\(extension)"))
    }
    
    func testGenerateUniqueKey_WithPrefixAndExtension() {
        // Arrange
        let prefix = "uploads"
        let extension = "pdf"
        
        // Act
        let key = service.generateUniqueKey(prefix: prefix, fileExtension: extension)
        
        // Assert
        XCTAssertTrue(key.hasPrefix("\(prefix)/"))
        XCTAssertTrue(key.hasSuffix(".\(extension)"))
    }
}

// MARK: - Mock S3 Client for Testing

class AWSS3MockClient: AWSS3 {
    
    // MARK: - Singleton
    
    static let shared = AWSS3MockClient()
    
    // MARK: - Properties
    
    private var database: [String: [String: Any]] = [:] // bucket -> key -> file data
    private var operationLog: [Operation] = []
    private var simulatedDelay: TimeInterval = 0.0
    private var shouldFailOperations = false
    private var customError: NSError?
    private var retrySuccessAfterAttempt: Int?
    private var currentAttemptCount: [String: Int] = [:] // Tracks attempts per key
    private var mockPresignedURL: URL?
    
    // MARK: - Configuration Methods
    
    func reset() {
        database = [:]
        operationLog = []
        shouldFailOperations = false
        customError = nil
        simulatedDelay = 0.0
        retrySuccessAfterAttempt = nil
        currentAttemptCount = [:]
        mockPresignedURL = nil
    }
    
    func setSimulatedDelay(_ seconds: TimeInterval) {
        simulatedDelay = seconds
    }
    
    func setFailureMode(shouldFail: Bool, error: NSError? = nil) {
        shouldFailOperations = shouldFail
        customError = error
    }
    
    func setRetrySuccessAfter(attempts: Int) {
        retrySuccessAfterAttempt = attempts
    }
    
    func addStoredFile(key: String, data: Data, bucket: String = "signal-content-attachments") {
        if database[bucket] == nil {
            database[bucket] = [:]
        }
        database[bucket]?[key] = data
    }
    
    func setPresignedURL(_ url: URL) {
        mockPresignedURL = url
    }
    
    // MARK: - Tracking Methods
    
    func getOperationLog() -> [Operation] {
        return operationLog
    }
    
    func getOperationCount(type: OperationType) -> Int {
        return operationLog.filter { $0.type == type }.count
    }
    
    // MARK: - S3 Operation Overrides
    
    override func putObject(_ request: AWSS3PutObjectRequest) -> AWSTask<AWSS3PutObjectOutput> {
        let operationType: OperationType = .putObject
        let key = request.key ?? "unknown-key"
        let bucket = request.bucket ?? "unknown-bucket"
        
        operationLog.append(Operation(
            type: operationType,
            key: key,
            bucket: bucket,
            contentType: request.contentType,
            contentLength: request.contentLength?.intValue
        ))
        
        incrementAttemptCount(for: key)
        
        // Handle retry success cases
        if let retrySuccessAfter = retrySuccessAfterAttempt,
           let attempts = currentAttemptCount[key],
           shouldFailOperations && attempts <= retrySuccessAfter {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.serviceUnavailable.rawValue,
                userInfo: nil
            ))
        }
        
        // Handle general failure mode
        if shouldFailOperations {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.internalError.rawValue,
                userInfo: nil
            ))
        }
        
        // Store the file in our mock database
        if database[bucket] == nil {
            database[bucket] = [:]
        }
        if let body = request.body as? Data {
            database[bucket]?[key] = body
        }
        
        let output = AWSS3PutObjectOutput()
        return AWSTask(result: output)
    }
    
    override func getObject(_ request: AWSS3GetObjectRequest) -> AWSTask<AWSS3GetObjectOutput> {
        let operationType: OperationType = .getObject
        let key = request.key ?? "unknown-key"
        let bucket = request.bucket ?? "unknown-bucket"
        
        operationLog.append(Operation(
            type: operationType,
            key: key,
            bucket: bucket
        ))
        
        incrementAttemptCount(for: key)
        
        // Handle retry success cases
        if let retrySuccessAfter = retrySuccessAfterAttempt,
           let attempts = currentAttemptCount[key],
           shouldFailOperations && attempts <= retrySuccessAfter {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.serviceUnavailable.rawValue,
                userInfo: nil
            ))
        }
        
        // Handle general failure mode
        if shouldFailOperations {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.internalError.rawValue,
                userInfo: nil
            ))
        }
        
        // Check if file exists
        guard let bucketData = database[bucket],
              let fileData = bucketData[key] as? Data else {
            return AWSTask(error: NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.noSuchKey.rawValue,
                userInfo: nil
            ))
        }
        
        let output = AWSS3GetObjectOutput()
        output.body = fileData
        return AWSTask(result: output)
    }
    
    override func headObject(_ request: AWSS3HeadObjectRequest) -> AWSTask<AWSS3HeadObjectOutput> {
        let operationType: OperationType = .headObject
        let key = request.key ?? "unknown-key"
        let bucket = request.bucket ?? "unknown-bucket"
        
        operationLog.append(Operation(
            type: operationType,
            key: key,
            bucket: bucket
        ))
        
        incrementAttemptCount(for: key)
        
        // Handle retry success cases
        if let retrySuccessAfter = retrySuccessAfterAttempt,
           let attempts = currentAttemptCount[key],
           shouldFailOperations && attempts <= retrySuccessAfter {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.serviceUnavailable.rawValue,
                userInfo: nil
            ))
        }
        
        // Handle general failure mode
        if shouldFailOperations {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.internalError.rawValue,
                userInfo: nil
            ))
        }
        
        // Check if file exists
        guard let bucketData = database[bucket],
              bucketData[key] != nil else {
            return AWSTask(error: NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.noSuchKey.rawValue,
                userInfo: nil
            ))
        }
        
        let output = AWSS3HeadObjectOutput()
        return AWSTask(result: output)
    }
    
    override func deleteObject(_ request: AWSS3DeleteObjectRequest) -> AWSTask<AWSS3DeleteObjectOutput> {
        let operationType: OperationType = .deleteObject
        let key = request.key ?? "unknown-key"
        let bucket = request.bucket ?? "unknown-bucket"
        
        operationLog.append(Operation(
            type: operationType,
            key: key,
            bucket: bucket
        ))
        
        incrementAttemptCount(for: key)
        
        // Handle retry success cases
        if let retrySuccessAfter = retrySuccessAfterAttempt,
           let attempts = currentAttemptCount[key],
           shouldFailOperations && attempts <= retrySuccessAfter {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.serviceUnavailable.rawValue,
                userInfo: nil
            ))
        }
        
        // Handle general failure mode
        if shouldFailOperations {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.internalError.rawValue,
                userInfo: nil
            ))
        }
        
        // Remove the file from our mock database
        database[bucket]?[key] = nil
        
        let output = AWSS3DeleteObjectOutput()
        return AWSTask(result: output)
    }
    
    // Mock for pre-signed URL generation
    func getPreSignedURL(_ request: AWSS3GetPreSignedURLRequest) -> AWSTask<URL> {
        let operationType: OperationType = .getPreSignedURL
        let key = request.key ?? "unknown-key"
        let bucket = request.bucket ?? "unknown-bucket"
        
        operationLog.append(Operation(
            type: operationType,
            key: key,
            bucket: bucket
        ))
        
        incrementAttemptCount(for: key)
        
        // Handle retry success cases
        if let retrySuccessAfter = retrySuccessAfterAttempt,
           let attempts = currentAttemptCount[key],
           shouldFailOperations && attempts <= retrySuccessAfter {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.serviceUnavailable.rawValue,
                userInfo: nil
            ))
        }
        
        // Handle general failure mode
        if shouldFailOperations {
            return AWSTask(error: customError ?? NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.internalError.rawValue,
                userInfo: nil
            ))
        }
        
        if let mockURL = mockPresignedURL {
            return AWSTask(result: mockURL)
        }
        
        // Generate a mock URL
        guard let url = URL(string: "https://s3.amazonaws.com/\(bucket)/\(key)?AWSAccessKeyId=mock&Signature=mock&Expires=mock") else {
            return AWSTask(error: NSError(
                domain: AWSS3ErrorDomain,
                code: AWSS3ErrorType.internalError.rawValue,
                userInfo: nil
            ))
        }
        
        return AWSTask(result: url)
    }
    
    // MARK: - Helper Methods
    
    private func incrementAttemptCount(for key: String) {
        currentAttemptCount[key] = (currentAttemptCount[key] ?? 0) + 1
    }
    
    // MARK: - Types
    
    enum OperationType: String {
        case putObject
        case getObject
        case headObject
        case deleteObject
        case getPreSignedURL
    }
    
    struct Operation {
        let id: UUID = UUID()
        let type: OperationType
        let key: String
        let bucket: String
        let contentType: String?
        let contentLength: Int?
        let timestamp = Date()
        
        init(type: OperationType, key: String, bucket: String, contentType: String? = nil, contentLength: Int? = nil) {
            self.type = type
            self.key = key
            self.bucket = bucket
            self.contentType = contentType
            self.contentLength = contentLength
        }
    }
}

// MARK: - Testable S3Service Subclass

class TestableSEService: S3Service {
    private let mockClient: AWSS3
    
    init(mockClient: AWSS3) {
        self.mockClient = mockClient
        super.init()
        
        // Override the AWS client using runtime configuration
        let clientIvar = class_getInstanceVariable(S3Service.self, "_client")
        if let clientIvar = clientIvar {
            object_setIvar(self, clientIvar, mockClient)
        }
    }
}
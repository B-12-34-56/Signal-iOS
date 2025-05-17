//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSDynamoDB
import AWSAPIGateway
import AWSCognitoIdentity
import Logging
import SignalServiceKit

/// A comprehensive mock implementation for testing AWS services in the duplicate content detection system.
class AWSServiceMock {

    // MARK: - Configuration
    
    struct Config {
        var shouldThrowCredentialErrors = false
        var shouldThrowDynamoDBErrors = false
        var shouldThrowAPIGatewayErrors = false
        var simulateNetworkDelay: TimeInterval = 0.0
        var simulateRateLimiting = false
        var maxRateLimitRetries = 3
    }
    
    // MARK: - Properties
    
    /// Configuration object for mock behavior
    private var config: Config
    
    /// Logger instance
    private let logger: Logger
    
    /// Mock storage for DynamoDB items
    private var dynamoDBStorage: [String: Any] = [:]
    
    /// Call tracking for verification
    private var callLog: [(service: String, method: String, timestamp: Date, parameters: [String: Any])] = []
    
    /// Rate limit tracking
    private var rateLimitCounters: [String: Int] = [:]
    
    /// Mock table structure
    private let tableStructure = [
        "TableName": "SignalContentHashes",
        "KeySchema": [
            ["AttributeName": "ContentHash", "KeyType": "HASH"]
        ],
        "AttributeDefinitions": [
            ["AttributeName": "ContentHash", "AttributeType": "S"],
            ["AttributeName": "TTL", "AttributeType": "N"]
        ],
        "BillingMode": "PAY_PER_REQUEST"
    ]
    
    // MARK: - Initialization
    
    init(config: Config = Config(), logger: Logger = Logger(label: "org.signal.tests.AWSServiceMock")) {
        self.config = config
        self.logger = logger
    }
    
    // MARK: - Mock Credentials Provider

    class MockCognitoCredentialsProvider: AWSCognitoCredentialsProvider {
        private let shouldFail: Bool
        private let mockIdentityId = "us-east-1:00000000-0000-0000-0000-000000000000"
        private let mockCredentials = ["accessKey": "MOCKAKIAXXXXXXXXXXXXXXXX",
                                     "secretKey": "mock0000000000000000000000000000000000000000"]
        
        init(shouldFail: Bool) {
            self.shouldFail = shouldFail
            super.init()
        }
        
        override func getIdentityId() -> AWSTask<NSString> {
            if shouldFail {
                return AWSTask(error: NSError(domain: AWSCognitoIdentityErrorDomain,
                                            code: AWSCognitoIdentityErrorType.notAuthorized.rawValue,
                                            userInfo: nil))
            }
            return AWSTask(result: mockIdentityId as NSString)
        }
        
        override func credentials() -> AWSTask<AWSCredentials> {
            if shouldFail {
                return AWSTask(error: NSError(domain: AWSCognitoIdentityErrorDomain,
                                            code: AWSCognitoIdentityErrorType.notAuthorized.rawValue,
                                            userInfo: nil))
            }
            let credentials = AWSCredentials(accessKey: mockCredentials["accessKey"]!,
                                          secretKey: mockCredentials["secretKey"]!,
                                          sessionKey: nil,
                                          expiration: Date().addingTimeInterval(3600))
            return AWSTask(result: credentials)
        }
    }
    
    // MARK: - Mock DynamoDB Client

    class MockDynamoDBClient {
        private let mock: AWSServiceMock
        
        init(mock: AWSServiceMock) {
            self.mock = mock
        }
        
        func putItem(_ request: AWSDynamoDBPutItemInput) -> AWSTask<AWSDynamoDBPutItemOutput> {
            mock.logCall(service: "DynamoDB", method: "putItem", parameters: ["item": request.item ?? [:]])
            
            if mock.config.shouldThrowDynamoDBErrors {
                return AWSTask(error: NSError(domain: AWSDynamoDBErrorDomain,
                                            code: AWSDynamoDBErrorType.internalServer.rawValue,
                                            userInfo: nil))
            }
            
            if mock.shouldRateLimit(operation: "putItem") {
                return AWSTask(error: NSError(domain: AWSDynamoDBErrorDomain,
                                            code: AWSDynamoDBErrorType.provisionedThroughputExceeded.rawValue,
                                            userInfo: nil))
            }
            
            // Simulate network delay
            if mock.config.simulateNetworkDelay > 0 {
                Thread.sleep(forTimeInterval: mock.config.simulateNetworkDelay)
            }
            
            // Store the item
            if let hashKey = request.item?["ContentHash"] as? [String: String],
               let hashValue = hashKey["S"] {
                mock.dynamoDBStorage[hashValue] = request.item
            }
            
            return AWSTask(result: AWSDynamoDBPutItemOutput())
        }
        
        func getItem(_ request: AWSDynamoDBGetItemInput) -> AWSTask<AWSDynamoDBGetItemOutput> {
            mock.logCall(service: "DynamoDB", method: "getItem", parameters: ["key": request.key ?? [:]])
            
            if mock.config.shouldThrowDynamoDBErrors {
                return AWSTask(error: NSError(domain: AWSDynamoDBErrorDomain,
                                            code: AWSDynamoDBErrorType.internalServer.rawValue,
                                            userInfo: nil))
            }
            
            if mock.shouldRateLimit(operation: "getItem") {
                return AWSTask(error: NSError(domain: AWSDynamoDBErrorDomain,
                                            code: AWSDynamoDBErrorType.provisionedThroughputExceeded.rawValue,
                                            userInfo: nil))
            }
            
            // Simulate network delay
            if mock.config.simulateNetworkDelay > 0 {
                Thread.sleep(forTimeInterval: mock.config.simulateNetworkDelay)
            }
            
            // Get the item
            if let hashKey = request.key?["ContentHash"] as? [String: String],
               let hashValue = hashKey["S"],
               let item = mock.dynamoDBStorage[hashValue] {
                let output = AWSDynamoDBGetItemOutput()
                output.item = item as? [String: Any]
                return AWSTask(result: output)
            }
            
            // Item not found
            let output = AWSDynamoDBGetItemOutput()
            output.item = nil
            return AWSTask(result: output)
        }
        
        func deleteItem(_ request: AWSDynamoDBDeleteItemInput) -> AWSTask<AWSDynamoDBDeleteItemOutput> {
            mock.logCall(service: "DynamoDB", method: "deleteItem", parameters: ["key": request.key ?? [:]])
            
            if mock.config.shouldThrowDynamoDBErrors {
                return AWSTask(error: NSError(domain: AWSDynamoDBErrorDomain,
                                            code: AWSDynamoDBErrorType.internalServer.rawValue,
                                            userInfo: nil))
            }
            
            if mock.shouldRateLimit(operation: "deleteItem") {
                return AWSTask(error: NSError(domain: AWSDynamoDBErrorDomain,
                                            code: AWSDynamoDBErrorType.provisionedThroughputExceeded.rawValue,
                                            userInfo: nil))
            }
            
            // Simulate network delay
            if mock.config.simulateNetworkDelay > 0 {
                Thread.sleep(forTimeInterval: mock.config.simulateNetworkDelay)
            }
            
            // Delete the item
            if let hashKey = request.key?["ContentHash"] as? [String: String],
               let hashValue = hashKey["S"] {
                mock.dynamoDBStorage.removeValue(forKey: hashValue)
            }
            
            return AWSTask(result: AWSDynamoDBDeleteItemOutput())
        }
        
        func describeTable(_ request: AWSDynamoDBDescribeTableInput) -> AWSTask<AWSDynamoDBDescribeTableOutput> {
            mock.logCall(service: "DynamoDB", method: "describeTable", parameters: ["tableName": request.tableName ?? ""])
            
            let output = AWSDynamoDBDescribeTableOutput()
            output.table = AWSDynamoDBTableDescription()
            
            // Use stored table structure
            output.table?.tableName = mock.tableStructure["TableName"] as? String
            output.table?.keySchema = mock.tableStructure["KeySchema"] as? [AWSDynamoDBKeySchemaElement]
            output.table?.attributeDefinitions = mock.tableStructure["AttributeDefinitions"] as? [AWSDynamoDBAttributeDefinition]
            output.table?.billingModeSummary?.billingMode = .payPerRequest
            output.table?.tableStatus = .active
            
            return AWSTask(result: output)
        }
    }
    
    // MARK: - Mock API Gateway Client

    class MockAPIGatewayClient {
        private let mock: AWSServiceMock
        
        init(mock: AWSServiceMock) {
            self.mock = mock
        }
        
        func execute(_ request: AWSAPIGatewayRequest) -> AWSTask<AWSAPIGatewayResponse> {
            mock.logCall(service: "APIGateway", method: "execute", parameters: ["path": request.url?.path ?? ""])
            
            if mock.config.shouldThrowAPIGatewayErrors {
                return AWSTask(error: NSError(domain: AWSAPIGatewayErrorDomain,
                                            code: AWSAPIGatewayErrorType.invalidRequest.rawValue,
                                            userInfo: nil))
            }
            
            if mock.shouldRateLimit(operation: "execute") {
                return AWSTask(error: NSError(domain: AWSAPIGatewayErrorDomain,
                                            code: 429, // Too Many Requests
                                            userInfo: nil))
            }
            
            // Simulate network delay
            if mock.config.simulateNetworkDelay > 0 {
                Thread.sleep(forTimeInterval: mock.config.simulateNetworkDelay)
            }
            
            // Create mock response
            let response = AWSAPIGatewayResponse()
            response.statusCode = NSNumber(value: 200)
            response.headers = ["Content-Type": "application/json"]
            response.body = "{}".data(using: .utf8)
            
            return AWSTask(result: response)
        }
    }
    
    // MARK: - Mock Global Signature Service

    class MockGlobalSignatureService {
        private let mock: AWSServiceMock
        private var storedHashes: Set<String> = []
        
        init(mock: AWSServiceMock) {
            self.mock = mock
        }
        
        func contains(_ hash: String) async -> Bool {
            mock.logCall(service: "GlobalSignatureService", method: "contains", parameters: ["hash": hash])
            return storedHashes.contains(hash)
        }
        
        func store(_ hash: String) async -> Bool {
            mock.logCall(service: "GlobalSignatureService", method: "store", parameters: ["hash": hash])
            storedHashes.insert(hash)
            return true
        }
        
        func delete(_ hash: String) async -> Bool {
            mock.logCall(service: "GlobalSignatureService", method: "delete", parameters: ["hash": hash])
            storedHashes.remove(hash)
            return true
        }
        
        func batchContains(hashes: [String]) async -> [String: Bool]? {
            mock.logCall(service: "GlobalSignatureService", method: "batchContains", parameters: ["hashes": hashes])
            return Dictionary(uniqueKeysWithValues: hashes.map { ($0, storedHashes.contains($0)) })
        }
        
        func reset() {
            storedHashes.removeAll()
        }
    }
    
    // MARK: - Helper Methods
    
    private func logCall(service: String, method: String, parameters: [String: Any]) {
        callLog.append((service: service,
                       method: method,
                       timestamp: Date(),
                       parameters: parameters))
        logger.debug("[\(service)] Called \(method) with parameters: \(parameters)")
    }
    
    private func shouldRateLimit(operation: String) -> Bool {
        guard config.simulateRateLimiting else { return false }
        
        let key = "\(operation)_\(Int(Date().timeIntervalSince1970))"
        let count = rateLimitCounters[key, default: 0] + 1
        rateLimitCounters[key] = count
        
        return count > config.maxRateLimitRetries
    }
    
    // MARK: - Public Interface
    
    /// Returns a mock credentials provider
    func getMockCredentialsProvider() -> AWSCognitoCredentialsProvider {
        return MockCognitoCredentialsProvider(shouldFail: config.shouldThrowCredentialErrors)
    }
    
    /// Returns a mock DynamoDB client
    func getMockDynamoDBClient() -> MockDynamoDBClient {
        return MockDynamoDBClient(mock: self)
    }
    
    /// Returns a mock API Gateway client
    func getMockAPIGatewayClient() -> MockAPIGatewayClient {
        return MockAPIGatewayClient(mock: self)
    }
    
    /// Returns a mock Global Signature Service
    func getMockGlobalSignatureService() -> MockGlobalSignatureService {
        return MockGlobalSignatureService(mock: self)
    }
    
    /// Updates the mock configuration
    func updateConfig(_ config: Config) {
        self.config = config
    }
    
    /// Retrieves the call log for verification
    func getCallLog() -> [(service: String, method: String, timestamp: Date, parameters: [String: Any])] {
        return callLog
    }
    
    /// Clears all mock state (storage, logs, counters)
    func reset() {
        dynamoDBStorage.removeAll()
        callLog.removeAll()
        rateLimitCounters.removeAll()
    }
}

// MARK: - Test Helper Extensions

extension AWSTask {
    func await<T>() async throws -> T where T == ResultType {
        return try await withCheckedThrowingContinuation { continuation in
            self.continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else if let result = task.result as? T {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AWSServiceMock",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected result type"]
                    ))
                }
                return nil
            }
        }
    }
}
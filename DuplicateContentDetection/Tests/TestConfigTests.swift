import XCTest
import SignalServiceKit
import AWSCore
import AWSDynamoDB
import AWSS3
@testable import DuplicateContentDetection
import Logging

class TestConfigTests: XCTestCase {
    // MARK: - Properties
    
    private var testConfig: TestConfig!
    private var mockEnvironment: [String: String] = [:]
    
    // MARK: - Setup
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Setup mock environment
        mockEnvironment = [
            "AWS_REGION": "us-west-2",
            "AWS_ACCESS_KEY": "test-access-key",
            "AWS_SECRET_KEY": "test-secret-key",
            "AWS_SESSION_TOKEN": "test-session-token",
            "S3_BUCKET": "test-bucket",
            "DYNAMODB_TABLE": "test-table",
            "LAMBDA_FUNCTION": "test-function",
            "API_GATEWAY_ENDPOINT": "https://api.example.com",
            "TEST_TIMEOUT": "30",
            "MAX_RETRIES": "3",
            "LOG_LEVEL": "debug"
        ]
        
        // Create test config with mock environment
        testConfig = TestConfig()
    }
    
    // MARK: - Tests
    
    func testGetValue() {
        // Test existing value
        XCTAssertEqual(
            testConfig.getValue(for: .awsRegion),
            mockEnvironment["AWS_REGION"]
        )
        
        // Test non-existent value
        XCTAssertNil(testConfig.getValue(for: .logLevel))
    }
    
    func testGetValueWithDefault() {
        // Test existing value
        XCTAssertEqual(
            testConfig.getValue(for: .awsRegion, defaultValue: "default-region"),
            mockEnvironment["AWS_REGION"]
        )
        
        // Test non-existent value
        XCTAssertEqual(
            testConfig.getValue(for: .logLevel, defaultValue: "info"),
            "info"
        )
    }
    
    func testGetNumericValue() {
        // Test valid numeric value
        XCTAssertEqual(
            testConfig.getNumericValue(for: .testTimeout, defaultValue: 60),
            30
        )
        
        // Test invalid numeric value
        XCTAssertEqual(
            testConfig.getNumericValue(for: .maxRetries, defaultValue: 5),
            5
        )
    }
    
    func testGetBooleanValue() {
        // Test true value
        XCTAssertTrue(
            testConfig.getBooleanValue(for: .logLevel, defaultValue: false)
        )
        
        // Test false value
        XCTAssertFalse(
            testConfig.getBooleanValue(for: .awsRegion, defaultValue: false)
        )
    }
    
    func testValidateConfiguration() {
        // Test valid configuration
        XCTAssertNoThrow(try testConfig.validateConfiguration())
        
        // Test missing required configuration
        mockEnvironment.removeValue(forKey: "AWS_REGION")
        XCTAssertThrowsError(try testConfig.validateConfiguration()) { error in
            guard let configError = error as? TestConfigError else {
                XCTFail("Expected TestConfigError")
                return
            }
            
            switch configError {
            case .missingConfiguration(let key):
                XCTAssertEqual(key, .awsRegion)
            default:
                XCTFail("Expected missingConfiguration error")
            }
        }
    }
    
    func testLoadConfigFile() {
        // Create temporary config file
        let tempDir = FileManager.default.temporaryDirectory
        let configFile = tempDir.appendingPathComponent("test_config.json")
        
        let configData = """
        {
            "AWS_REGION": "us-east-1",
            "S3_BUCKET": "config-file-bucket"
        }
        """.data(using: .utf8)!
        
        try? configData.write(to: configFile)
        
        // Test loading from file
        XCTAssertEqual(
            testConfig.getValue(for: .awsRegion),
            "us-east-1"
        )
        XCTAssertEqual(
            testConfig.getValue(for: .s3Bucket),
            "config-file-bucket"
        )
        
        // Cleanup
        try? FileManager.default.removeItem(at: configFile)
    }
    
    func testConfigurationPriority() {
        // Environment variable should take precedence over config file
        XCTAssertEqual(
            testConfig.getValue(for: .awsRegion),
            mockEnvironment["AWS_REGION"]
        )
        
        // Remove environment variable
        mockEnvironment.removeValue(forKey: "AWS_REGION")
        
        // Should fall back to config file
        XCTAssertEqual(
            testConfig.getValue(for: .awsRegion),
            "us-east-1"
        )
    }
    
    func testErrorHandling() {
        // Test invalid configuration file
        let tempDir = FileManager.default.temporaryDirectory
        let invalidConfigFile = tempDir.appendingPathComponent("invalid_config.json")
        
        let invalidData = "invalid json".data(using: .utf8)!
        try? invalidData.write(to: invalidConfigFile)
        
        XCTAssertNoThrow(try testConfig.validateConfiguration())
        
        // Cleanup
        try? FileManager.default.removeItem(at: invalidConfigFile)
    }
} 
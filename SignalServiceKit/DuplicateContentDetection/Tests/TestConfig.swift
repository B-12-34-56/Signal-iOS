import Foundation
import SignalServiceKit
import AWSCore
import AWSDynamoDB
import AWSS3
import Logging

/// Manages test configuration and environment variables
class TestConfig {
    // MARK: - Properties
    
    static let shared = TestConfig()
    
    private let logger: Logger
    private let environment: [String: String]
    private let configFile: URL?
    
    // MARK: - Configuration Keys
    
    enum ConfigKey: String {
        case awsRegion = "AWS_REGION"
        case awsAccessKey = "AWS_ACCESS_KEY"
        case awsSecretKey = "AWS_SECRET_KEY"
        case awsSessionToken = "AWS_SESSION_TOKEN"
        case s3Bucket = "S3_BUCKET"
        case dynamoDBTable = "DYNAMODB_TABLE"
        case lambdaFunction = "LAMBDA_FUNCTION"
        case apiGatewayEndpoint = "API_GATEWAY_ENDPOINT"
        case testTimeout = "TEST_TIMEOUT"
        case maxRetries = "MAX_RETRIES"
        case logLevel = "LOG_LEVEL"
    }
    
    // MARK: - Initialization
    
    private init() {
        self.logger = Logger(label: "org.signal.TestConfig")
        self.environment = ProcessInfo.processInfo.environment
        
        // Load configuration file if it exists
        let configPath = FileManager.default.currentDirectoryPath + "/test_config.json"
        self.configFile = URL(fileURLWithPath: configPath)
        
        loadConfiguration()
    }
    
    // MARK: - Public Methods
    
    /// Gets a configuration value
    /// - Parameter key: The configuration key
    /// - Returns: The configuration value
    func getValue(for key: ConfigKey) -> String? {
        // Check environment variables first
        if let value = environment[key.rawValue] {
            return value
        }
        
        // Check configuration file
        if let config = loadConfigFile(),
           let value = config[key.rawValue] as? String {
            return value
        }
        
        return nil
    }
    
    /// Gets a configuration value with a default
    /// - Parameters:
    ///   - key: The configuration key
    ///   - defaultValue: The default value
    /// - Returns: The configuration value or default
    func getValue(for key: ConfigKey, defaultValue: String) -> String {
        return getValue(for: key) ?? defaultValue
    }
    
    /// Gets a numeric configuration value
    /// - Parameters:
    ///   - key: The configuration key
    ///   - defaultValue: The default value
    /// - Returns: The numeric value
    func getNumericValue(for key: ConfigKey, defaultValue: Int) -> Int {
        guard let value = getValue(for: key),
              let numericValue = Int(value) else {
            return defaultValue
        }
        return numericValue
    }
    
    /// Gets a boolean configuration value
    /// - Parameters:
    ///   - key: The configuration key
    ///   - defaultValue: The default value
    /// - Returns: The boolean value
    func getBooleanValue(for key: ConfigKey, defaultValue: Bool) -> Bool {
        guard let value = getValue(for: key) else {
            return defaultValue
        }
        return value.lowercased() == "true"
    }
    
    /// Validates the test configuration
    /// - Throws: Error if configuration is invalid
    func validateConfiguration() throws {
        // Check required AWS configuration
        guard getValue(for: .awsRegion) != nil else {
            throw TestConfigError.missingConfiguration(key: .awsRegion)
        }
        
        guard getValue(for: .awsAccessKey) != nil else {
            throw TestConfigError.missingConfiguration(key: .awsAccessKey)
        }
        
        guard getValue(for: .awsSecretKey) != nil else {
            throw TestConfigError.missingConfiguration(key: .awsSecretKey)
        }
        
        // Check required service endpoints
        guard getValue(for: .s3Bucket) != nil else {
            throw TestConfigError.missingConfiguration(key: .s3Bucket)
        }
        
        guard getValue(for: .dynamoDBTable) != nil else {
            throw TestConfigError.missingConfiguration(key: .dynamoDBTable)
        }
        
        logger.info("Test configuration validated successfully")
    }
    
    // MARK: - Private Methods
    
    private func loadConfiguration() {
        do {
            try validateConfiguration()
        } catch {
            logger.error("Failed to validate test configuration: \(error)")
        }
    }
    
    private func loadConfigFile() -> [String: Any]? {
        guard let configFile = configFile,
              FileManager.default.fileExists(atPath: configFile.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: configFile)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logger.error("Failed to load configuration file: \(error)")
            return nil
        }
    }
}

// MARK: - Error Types

enum TestConfigError: Error {
    case missingConfiguration(key: TestConfig.ConfigKey)
    case invalidConfiguration(key: TestConfig.ConfigKey)
    case configurationFileError(Error)
    
    var localizedDescription: String {
        switch self {
        case .missingConfiguration(let key):
            return "Missing required configuration: \(key.rawValue)"
        case .invalidConfiguration(let key):
            return "Invalid configuration value for: \(key.rawValue)"
        case .configurationFileError(let error):
            return "Configuration file error: \(error.localizedDescription)"
        }
    }
}

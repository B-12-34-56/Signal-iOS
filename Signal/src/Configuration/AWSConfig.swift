//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore

enum AWSConfigError: Error {
    case missingRequiredValue(String)
    case invalidValue(String)
    case configurationError(String)
}

class AWSConfig {
    static let shared = AWSConfig()
    
    // MARK: - S3 Configuration
    let s3BucketName: String
    let s3Region: String
    let s3ImagesPath: String
    let s3BaseURL: String
    
    // MARK: - DynamoDB Configuration
    let dynamoDbTableName: String
    let dynamoDbRegion: String
    let dynamoDbEndpoint: String
    
    // MARK: - API Gateway Endpoints
    let apiGatewayEndpoint: String
    let getTagApiGatewayEndpoint: String
    let uploadImageApiGatewayEndpoint: String
    
    // MARK: - Cognito Configuration
    let identityPoolId: String
    let cognitoRegion: String
    
    // MARK: - API Keys
    let getTagApiKey: String
    let uploadImageApiKey: String
    
    // MARK: - DynamoDB Field Names
    let hashFieldName: String
    let timestampFieldName: String
    let ttlFieldName: String
    
    // MARK: - Timeouts and Retries
    let requestTimeoutInterval: TimeInterval
    let resourceTimeoutInterval: TimeInterval
    let maxRetryCount: Int
    let initialRetryDelay: TimeInterval
    let maxRetryDelay: TimeInterval
    
    // MARK: - TTL Configuration
    let defaultTTL: TimeInterval
    
    // MARK: - API Gateway ARNs
    let getTagApiGatewayArn: String
    let uploadImageApiGatewayArn: String
    
    private init() throws {
        // Load configuration from environment variables or use defaults
        self.s3BucketName = try Self.getRequiredValue("S3_BUCKET_NAME", default: "signal-image-uploads")
        self.s3Region = try Self.getRequiredValue("S3_REGION", default: "us-east-1")
        self.s3ImagesPath = try Self.getRequiredValue("S3_IMAGES_PATH", default: "images")
        self.s3BaseURL = try Self.getRequiredValue("S3_BASE_URL", default: "https://signal-image-uploads.s3.amazonaws.com")
        
        self.dynamoDbTableName = try Self.getRequiredValue("DYNAMODB_TABLE_NAME", default: "signal-image-signatures")
        self.dynamoDbRegion = try Self.getRequiredValue("DYNAMODB_REGION", default: "us-east-1")
        self.dynamoDbEndpoint = try Self.getRequiredValue("DYNAMODB_ENDPOINT", default: "https://dynamodb.us-east-1.amazonaws.com")
        
        self.apiGatewayEndpoint = try Self.getRequiredValue("API_GATEWAY_ENDPOINT", default: "https://api.signal.org")
        self.getTagApiGatewayEndpoint = "\(self.apiGatewayEndpoint)/get-tag"
        self.uploadImageApiGatewayEndpoint = "\(self.apiGatewayEndpoint)/upload-image"
        
        self.identityPoolId = try Self.getRequiredValue("COGNITO_IDENTITY_POOL_ID")
        self.cognitoRegion = try Self.getRequiredValue("COGNITO_REGION", default: "us-east-1")
        
        self.getTagApiKey = try Self.getRequiredValue("GET_TAG_API_KEY")
        self.uploadImageApiKey = try Self.getRequiredValue("UPLOAD_IMAGE_API_KEY")
        
        self.hashFieldName = "imageHash"
        self.timestampFieldName = "timestamp"
        self.ttlFieldName = "ttl"
        
        self.requestTimeoutInterval = TimeInterval(try Self.getRequiredValue("REQUEST_TIMEOUT", default: "30")) ?? 30
        self.resourceTimeoutInterval = TimeInterval(try Self.getRequiredValue("RESOURCE_TIMEOUT", default: "300")) ?? 300
        self.maxRetryCount = Int(try Self.getRequiredValue("MAX_RETRY_COUNT", default: "3")) ?? 3
        self.initialRetryDelay = TimeInterval(try Self.getRequiredValue("INITIAL_RETRY_DELAY", default: "1")) ?? 1
        self.maxRetryDelay = TimeInterval(try Self.getRequiredValue("MAX_RETRY_DELAY", default: "10")) ?? 10
        
        self.defaultTTL = TimeInterval(try Self.getRequiredValue("DEFAULT_TTL_DAYS", default: "30")) ?? 30 * 24 * 60 * 60
        
        self.getTagApiGatewayArn = try Self.getRequiredValue("GET_TAG_API_GATEWAY_ARN")
        self.uploadImageApiGatewayArn = try Self.getRequiredValue("UPLOAD_IMAGE_API_GATEWAY_ARN")
        
        try validateConfiguration()
    }
    
    private static func getRequiredValue(_ key: String, default defaultValue: String? = nil) throws -> String {
        if let value = ProcessInfo.processInfo.environment[key] {
            return value
        }
        if let defaultValue = defaultValue {
            return defaultValue
        }
        throw AWSConfigError.missingRequiredValue("Missing required configuration value: \(key)")
    }
    
    private func validateConfiguration() throws {
        // Validate URLs
        guard URL(string: s3BaseURL) != nil else {
            throw AWSConfigError.invalidValue("Invalid S3 base URL: \(s3BaseURL)")
        }
        
        guard URL(string: dynamoDbEndpoint) != nil else {
            throw AWSConfigError.invalidValue("Invalid DynamoDB endpoint: \(dynamoDbEndpoint)")
        }
        
        guard URL(string: apiGatewayEndpoint) != nil else {
            throw AWSConfigError.invalidValue("Invalid API Gateway endpoint: \(apiGatewayEndpoint)")
        }
        
        // Validate regions
        let validRegions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-1", "eu-central-1", "ap-southeast-1", "ap-southeast-2"]
        guard validRegions.contains(s3Region) else {
            throw AWSConfigError.invalidValue("Invalid S3 region: \(s3Region)")
        }
        
        guard validRegions.contains(dynamoDbRegion) else {
            throw AWSConfigError.invalidValue("Invalid DynamoDB region: \(dynamoDbRegion)")
        }
        
        guard validRegions.contains(cognitoRegion) else {
            throw AWSConfigError.invalidValue("Invalid Cognito region: \(cognitoRegion)")
        }
        
        // Validate timeouts and retries
        guard requestTimeoutInterval > 0 else {
            throw AWSConfigError.invalidValue("Request timeout must be greater than 0")
        }
        
        guard resourceTimeoutInterval > requestTimeoutInterval else {
            throw AWSConfigError.invalidValue("Resource timeout must be greater than request timeout")
        }
        
        guard maxRetryCount > 0 else {
            throw AWSConfigError.invalidValue("Max retry count must be greater than 0")
        }
        
        guard initialRetryDelay > 0 else {
            throw AWSConfigError.invalidValue("Initial retry delay must be greater than 0")
        }
        
        guard maxRetryDelay > initialRetryDelay else {
            throw AWSConfigError.invalidValue("Max retry delay must be greater than initial retry delay")
        }
        
        // Validate TTL
        guard defaultTTL > 0 else {
            throw AWSConfigError.invalidValue("Default TTL must be greater than 0")
        }
    }
    
    func configureAWS() throws {
        // Configure AWS Cognito
        let cognitoConfig = AWSCognitoCredentialsProvider(
            regionType: .USEast1,
            identityPoolId: identityPoolId
        )
        
        let configuration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: cognitoConfig
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
} 
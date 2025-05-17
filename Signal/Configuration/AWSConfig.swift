import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB
import AWSCognito

public enum AWSConfigError: Error {
    case missingRequiredValue(String)
    case invalidValue(String)
    case configurationError(String)
}

public enum AWSConfig {
    // MARK: - Core Configuration
    public static let region: AWSRegionType = .USEast1
    
    // MARK: - S3 Configuration
    public static let s3BucketName: String = ProcessInfo.processInfo.environment["S3_BUCKET_NAME"] ?? "2314823894myawsbucket"
    public static let s3ImagesPath: String = ProcessInfo.processInfo.environment["S3_IMAGES_PATH"] ?? "images"
    public static var s3BaseURL: String {
        "https://\(s3BucketName).s3.amazonaws.com/\(s3ImagesPath)"
    }
    
    // MARK: - DynamoDB Configuration
    public static let dynamoDbTableName: String = ProcessInfo.processInfo.environment["DYNAMODB_TABLE_NAME"] ?? "ImageSignatures"
    public static let dynamoDbRegion: AWSRegionType = .USEast1
    public static let dynamoDbTableArn: String = ProcessInfo.processInfo.environment["DYNAMODB_TABLE_ARN"] ?? "arn:aws:dynamodb:us-east-1:739874238091:table/ImageSignatures"
    
    // MARK: - Cognito Configuration
    public static let identityPoolId: String = ProcessInfo.processInfo.environment["COGNITO_IDENTITY_POOL_ID"] ?? "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c"
    public static let cognitoRegion: AWSRegionType = .USEast1
    
    // MARK: - API Gateway Configuration
    public static let apiGatewayEndpoint: String = ProcessInfo.processInfo.environment["API_GATEWAY_ENDPOINT"] ?? "https://ecf3rgso5g.execute-api.us-east-1.amazonaws.com/Stage1"
    
    // MARK: - AWS Credentials
    public static var awsAccessKey: String {
        ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] ?? ""
    }
    
    public static var awsSecretKey: String {
        ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] ?? ""
    }
    
    public static var awsSessionToken: String {
        ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"] ?? ""
    }
    
    // MARK: - Retry Configuration
    public static let maxRetryCount: Int = 3
    public static let initialRetryDelay: TimeInterval = 1.0
    public static let maxRetryDelay: TimeInterval = 10.0
    
    // MARK: - Configuration Methods
    public static func configureAWS() throws {
        // Configure AWS credentials
        let credentialsProvider: AWSCredentialsProvider
        
        if !awsSessionToken.isEmpty {
            // Use temporary credentials if session token is available
            Logger.info("Using temporary AWS credentials")
            credentialsProvider = AWSBasicSessionCredentialsProvider(
                accessKey: awsAccessKey,
                secretKey: awsSecretKey,
                sessionToken: awsSessionToken
            )
        } else {
            // Use Cognito for long-term credentials
            Logger.info("Using Cognito Identity Pool for AWS credentials")
            credentialsProvider = AWSCognitoCredentialsProvider(
                regionType: cognitoRegion,
                identityPoolId: identityPoolId
            )
        }
        
        let configuration = AWSServiceConfiguration(
            region: region,
            credentialsProvider: credentialsProvider
        )
        
        // Register services
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        AWSS3.register(with: configuration!, forKey: "S3")
        AWSDynamoDB.register(with: configuration!, forKey: "DynamoDB")
        
        Logger.info("AWS services configured successfully")
        Logger.info("Region: \(region.rawValue)")
        Logger.info("S3 Bucket: \(s3BucketName)")
        Logger.info("DynamoDB Table: \(dynamoDbTableName)")
        Logger.info("API Gateway: \(apiGatewayEndpoint)")
    }
    
    public static func validateConfiguration() throws {
        // Validate URLs
        guard URL(string: s3BaseURL) != nil else {
            throw AWSConfigError.invalidValue("Invalid S3 base URL: \(s3BaseURL)")
        }
        
        // Validate timeouts and retries
        guard maxRetryCount > 0 else {
            throw AWSConfigError.invalidValue("Max retry count must be greater than 0")
        }
        
        guard initialRetryDelay > 0 else {
            throw AWSConfigError.invalidValue("Initial retry delay must be greater than 0")
        }
        
        guard maxRetryDelay > initialRetryDelay else {
            throw AWSConfigError.invalidValue("Max retry delay must be greater than initial retry delay")
        }
    }
} 
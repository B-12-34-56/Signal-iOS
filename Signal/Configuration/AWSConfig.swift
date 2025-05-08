import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB
import AWSCognito

enum AWSConfigError: Error {
    case missingRequiredValue(String)
    case invalidValue(String)
    case configurationError(String)
}

class AWSConfig {
    static let shared = AWSConfig()
    
    // MARK: - S3 Configuration
    let s3BucketName: String
    let s3Region: AWSRegionType
    let s3ImagesPath: String
    let s3BaseURL: String
    
    // MARK: - DynamoDB Configuration
    let dynamoDbTableName: String
    let dynamoDbRegion: AWSRegionType
    let dynamoDbTableArn: String
    
    // MARK: - Cognito Configuration
    let identityPoolId: String
    let cognitoRegion: AWSRegionType
    
    // MARK: - Retry Configuration
    let maxRetryCount: Int
    let initialRetryDelay: TimeInterval
    let maxRetryDelay: TimeInterval
    
    private init() throws {
        // S3 Configuration
        self.s3BucketName = "2314823894myawsbucket"
        self.s3Region = .USEast1
        self.s3ImagesPath = "images"
        self.s3BaseURL = "https://\(s3BucketName).s3.amazonaws.com/\(s3ImagesPath)"
        
        // DynamoDB Configuration
        self.dynamoDbTableName = "ImageSignatures"
        self.dynamoDbRegion = .USEast1
        self.dynamoDbTableArn = "arn:aws:dynamodb:us-east-1:739874238091:table/ImageSignatures"
        
        // Cognito Configuration
        self.identityPoolId = "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c"
        self.cognitoRegion = .USEast1
        
        // Retry Configuration
        self.maxRetryCount = 3
        self.initialRetryDelay = 1.0
        self.maxRetryDelay = 10.0
        
        try validateConfiguration()
    }
    
    private func validateConfiguration() throws {
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
    
    func configureAWS() throws {
        // Configure AWS Cognito
        let cognitoConfig = AWSCognitoCredentialsProvider(
            regionType: cognitoRegion,
            identityPoolId: identityPoolId
        )
        
        let configuration = AWSServiceConfiguration(
            region: s3Region,
            credentialsProvider: cognitoConfig
        )
        
        // Register services
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        AWSS3.register(with: configuration!, forKey: "S3")
        AWSDynamoDB.register(with: configuration!, forKey: "DynamoDB")
    }
} 
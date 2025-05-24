import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB

struct TestConfig {
    static func setupAWS() {
        // Configure AWS credentials for testing
        let credentialsProvider = AWSCognitoCredentialsProvider(
            regionType: .USEast1,
            identityPoolId: "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c"
        )
        
        let configuration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentialsProvider
        )
        
        // Register services
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        AWSS3.register(with: configuration!, forKey: "S3")
        AWSDynamoDB.register(with: configuration!, forKey: "DynamoDB")
        
        // Set up test configuration values
        let testConfig = [
            "S3_BUCKET_NAME": "signal-image-uploads",
            "S3_REGION": "us-east-1",
            "S3_IMAGES_PATH": "images",
            "S3_BASE_URL": "https://signal-image-uploads.s3.amazonaws.com",
            "DYNAMODB_TABLE_NAME": "signal-image-signatures",
            "DYNAMODB_REGION": "us-east-1",
            "DYNAMODB_ENDPOINT": "https://dynamodb.us-east-1.amazonaws.com",
            "COGNITO_IDENTITY_POOL_ID": "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c",
            "COGNITO_REGION": "us-east-1"
        ]
        
        // Set environment variables
        for (key, value) in testConfig {
            setenv(key, value, 1)
        }
    }
} 
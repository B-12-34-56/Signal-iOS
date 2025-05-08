import Foundation
import AWSCore

struct AWSConfig {
    static let region = AWSRegionType.USEast1
    static let identityPoolId = "us-east-1:12345678-1234-1234-1234-123456789012"
    static let bucketName = "signal-images-bucket"
    static let tableName = "signal-image-signatures"
    
    static func configure() {
        // Configure AWS credentials
        let credentialsProvider = AWSCognitoCredentialsProvider(
            regionType: region,
            identityPoolId: identityPoolId
        )
        
        let configuration = AWSServiceConfiguration(
            region: region,
            credentialsProvider: credentialsProvider
        )
        
        // Register services
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        AWSDynamoDB.register(with: configuration!, forKey: "DynamoDB")
        AWSS3.register(with: configuration!, forKey: "S3")
    }
} 
import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB

struct AWSServiceBoot {
    static func configure() {
        do {
            // Initialize AWS configuration
            _ = try AWSConfig.shared
            
            // Configure AWS Cognito
            let cognitoConfig = AWSCognitoCredentialsProvider(
                regionType: AWSConfig.region,
                identityPoolId: AWSConfig.identityPoolId
            )
            
            let configuration = AWSServiceConfiguration(
                region: AWSConfig.region,
                credentialsProvider: cognitoConfig
            )
            
            // Register services
            AWSServiceManager.default().defaultServiceConfiguration = configuration
            AWSS3.register(with: configuration!, forKey: "S3")
            AWSDynamoDB.register(with: configuration!, forKey: "DynamoDB")
            
            Logger.info("AWS services configured successfully")
        } catch {
            Logger.error("Failed to configure AWS services: \(error)")
        }
    }
} 
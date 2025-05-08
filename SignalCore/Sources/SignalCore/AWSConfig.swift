import Foundation
import AWSCore

public class AWSConfig {
    public static let shared = AWSConfig()
    
    private init() {}
    
    // MARK: - Configuration
    
    public var configuration: AWSServiceConfiguration? {
        guard let credentialsProvider = credentialsProvider else { return nil }
        return AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentialsProvider
        )
    }
    
    public var credentialsProvider: AWSCredentialsProvider? {
        // For development, using environment variables
        // For production, use AWS Cognito or other secure methods
        return AWSStaticCredentialsProvider(accessKey: awsAccessKey, secretKey: awsSecretKey)
    }
    
    // MARK: - Configuration Values
    
    public var awsAccessKey: String {
        return ProcessInfo.processInfo.environment["AWS_ACCESS_KEY"] ?? ""
    }
    
    public var awsSecretKey: String {
        return ProcessInfo.processInfo.environment["AWS_SECRET_KEY"] ?? ""
    }
    
    public var bucketName: String {
        return ProcessInfo.processInfo.environment["AWS_S3_BUCKET"] ?? "signal-image-uploads"
    }
    
    public var baseURL: String {
        return "https://\(bucketName).s3.amazonaws.com"
    }
    
    public var signaturesTableName: String {
        return ProcessInfo.processInfo.environment["AWS_DYNAMODB_TABLE"] ?? "signal-image-signatures"
    }
} 
import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB

struct AWSServiceBoot {
    static func configure() {
        let access = Bundle.main.object(forInfoDictionaryKey: "AWS_ACCESS_KEY") as? String
        let secret = Bundle.main.object(forInfoDictionaryKey: "AWS_SECRET_KEY") as? String
        let region = Bundle.main.object(forInfoDictionaryKey: "AWS_REGION") as? String
        
        let credentialsProvider = AWSStaticCredentialsProvider(
            accessKey: access ?? "",
            secretKey: secret ?? ""
        )
        
        let serviceConfig = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentialsProvider
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = serviceConfig
        
        print("AWS ready")
    }
} 
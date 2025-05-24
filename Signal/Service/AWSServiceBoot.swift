import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB
import SignalServiceKit

struct AWSServiceBoot {
  static func configure() {
    // — Cognito credentials provider —
    let credentialsProvider = AWSCognitoCredentialsProvider(
      regionType: .USEast1,
      identityPoolId: "us-east-1:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    )

    // — Default AWS configuration —
    let serviceConfig = AWSServiceConfiguration(
      region: .USEast1,
      credentialsProvider: credentialsProvider
    )
    AWSServiceManager.default().defaultServiceConfiguration = serviceConfig

    // — Register S3 & DynamoDB clients (optional keys) —
    AWSS3.register(with: serviceConfig!, forKey: "S3")
    AWSDynamoDB.register(with: serviceConfig!, forKey: "DynamoDB")

    // — Enable SDK logging —
    AWSDDLog.sharedInstance.logLevel = .info

    Logger.info("AWS services configured successfully")
  }
}

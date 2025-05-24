import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB
import SignalServiceKit
import Signal

struct AWSServiceBoot {
  static func configure() {
    // Use canonical AWSConfig
    let config = try? AWSConfig.shared
    let credentialsProvider = AWSCognitoCredentialsProvider(
      regionType: .USEast1,
      identityPoolId: config?.identityPoolId ?? ""
    )
    let serviceConfig = AWSServiceConfiguration(
      region: .USEast1,
      credentialsProvider: credentialsProvider
    )
    AWSServiceManager.default().defaultServiceConfiguration = serviceConfig
    AWSS3.register(with: serviceConfig!, forKey: "S3")
    AWSDynamoDB.register(with: serviceConfig!, forKey: "DynamoDB")
    AWSDDLog.sharedInstance.logLevel = .info
    Logger.info("AWS services configured successfully")
  }
}

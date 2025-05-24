import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB
<<<<<<< HEAD

final class AWSServiceBoot {
  static func configure() {
    let region: AWSRegionType = .USEast1
    // Use static credentials for testing
    let credentialsProvider = AWSStaticCredentialsProvider(
      accessKey: "AKIAU6GD3P3JDEGAPNG5",
      secretKey: "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"
    )
    let serviceConfig = AWSServiceConfiguration(
      region: region,
      credentialsProvider: credentialsProvider
    )
    AWSServiceManager.default().defaultServiceConfiguration = serviceConfig
    // Register S3 client with test bucket
    AWSS3.register(with: serviceConfig!, forKey: "S3")
    // Optionally, set up S3 bucket and folder for uploads in your app logic:
    // S3 Bucket: filter-slide
    // S3 Folder: image-test/
    Logger.info("AWS services configured for testing with static credentials and S3 bucket 'filter-slide', folder 'image-test/'")
=======
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
>>>>>>> origin/Ibrahim
  }
}

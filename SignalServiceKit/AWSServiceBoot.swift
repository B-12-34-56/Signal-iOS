import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB
import SignalServiceKit

struct AWSServiceBoot {
  static func configure() {
    // — AWS credentials provider —
    let credentialsProvider = AWSStaticCredentialsProvider(
      accessKey: "AKIAU6GD3P3JDEGAPNG5",
      secretKey: "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"
    )

    // — Default AWS configuration —
    let serviceConfig = AWSServiceConfiguration(
      region: .USEast1,
      credentialsProvider: credentialsProvider
    )
    AWSServiceManager.default().defaultServiceConfiguration = serviceConfig

    // — Register S3 & DynamoDB clients —
    AWSS3.register(with: serviceConfig!, forKey: "S3")
    AWSDynamoDB.register(with: serviceConfig!, forKey: "DynamoDB")

    // — Enable SDK logging —
    AWSDDLog.sharedInstance.logLevel = .info

    Logger.info("AWS services configured successfully")
  }
} 
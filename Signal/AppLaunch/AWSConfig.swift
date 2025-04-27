// AWSConfig.swift
// Make sure this file is added to your Signal target

import Foundation
import AWSCore
import AWSCognitoIdentityProvider  // ensure your Podfile/SPM includes these

struct AWSConfig {
    /// Configure and attach your AWS credentials provider to AWSServiceManager.default()
    static func setupAWSCredentials() {
        let credentialsProvider = AWSCognitoCredentialsProvider(
            regionType: .USEast1,
            identityPoolId: "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c"
        )
        let configuration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentialsProvider
        )
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }

    /// Quickly check whether an identity has been fetched
    static func validateAWSCredentials() async -> Bool {
        guard let provider = AWSServiceManager
                .default()
                .defaultServiceConfiguration?
                .credentialsProvider as? AWSCognitoCredentialsProvider
        else {
            return false
        }

        // If identityId is non-nil, the provider has at least fetched or cached an ID
        return provider.identityId != nil
    }
}

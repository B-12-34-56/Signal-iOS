//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore

public enum GlobalEndpoints {
    // MARK: - API Gateway Configuration
    public static let apiGatewayEndpoint: String = ProcessInfo.processInfo.environment["API_GATEWAY_ENDPOINT"] ?? "https://ecf3rgso5g.execute-api.us-east-1.amazonaws.com/Stage1"
    
    // MARK: - API Gateway Endpoints
    public static let blockImageEndpoint  = "\(apiGatewayEndpoint)/block-image"
    public static let getTagEndpoint      = "\(apiGatewayEndpoint)/get-tag"
    public static let uploadImageEndpoint = "\(apiGatewayEndpoint)/upload-image"

    // MARK: - Lambda Function Names
    public static let contentProcessorFunction = "content-processor"
    public static let imageAnalyzerFunction    = "image-analyzer"

    // MARK: - API Keys
    public static let blockImageApiKey  = ProcessInfo.processInfo.environment["BLOCK_IMAGE_API_KEY"]  ?? ""
    public static let getTagApiKey      = ProcessInfo.processInfo.environment["GET_TAG_API_KEY"]      ?? ""
    public static let uploadImageApiKey = ProcessInfo.processInfo.environment["UPLOAD_IMAGE_API_KEY"] ?? ""
    
    // MARK: - AWS Credentials
    public static var awsAccessKey: String {
        ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] ?? ""
    }
    
    public static var awsSecretKey: String {
        ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] ?? ""
    }
    
    public static var awsSessionToken: String {
        ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"] ?? ""
    }
    
    // MARK: - Configuration Methods
    public static func configureAWS() throws {
        // Configure AWS credentials
        let credentialsProvider: AWSCredentialsProvider
        
        if !awsSessionToken.isEmpty {
            // Use temporary credentials if session token is available
            Logger.info("Using temporary AWS credentials")
            credentialsProvider = AWSBasicSessionCredentialsProvider(
                accessKey: awsAccessKey,
                secretKey: awsSecretKey,
                sessionToken: awsSessionToken
            )
        } else {
            // Use static credentials
            Logger.info("Using static AWS credentials")
            credentialsProvider = AWSStaticCredentialsProvider(
                accessKey: awsAccessKey,
                secretKey: awsSecretKey
            )
        }
        
        let configuration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentialsProvider
        )
        
        // Register services
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        
        Logger.info("AWS services configured successfully for duplicate content detection")
        Logger.info("API Gateway: \(apiGatewayEndpoint)")
    }
}

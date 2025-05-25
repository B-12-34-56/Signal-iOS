//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AWSS3
import AWSDynamoDB
import AWSCognito
import SignalServiceKit

class AWSService {
    static let shared = AWSService()
    
    private init() {
        setupAWS()
    }
    
    private func setupAWS() {
        // Configure AWS Cognito
        let cognitoConfig = AWSCognitoCredentialsProvider(
            regionType: .USEast1,
            identityPoolId: AWSConfig.identityPoolId
        )
        
        let configuration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: cognitoConfig
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
    
    // MARK: - Image Upload
    
    func uploadImage(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(.failure(NSError(domain: "AWSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])))
            return
        }
        
        let key = "\(AWSConfig.s3ImagesPath)/\(UUID().uuidString).jpg"
        let request = AWSS3PutObjectRequest()
        request?.bucket = AWSConfig.s3BucketName
        request?.key = key
        request?.body = imageData
        request?.contentType = "image/jpeg"
        
        AWSS3.default().putObject(request!) { response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            let imageURL = "\(AWSConfig.s3BaseURL)/\(key)"
            completion(.success(imageURL))
        }
    }
    
    // MARK: - Image Signature Management
    
    func storeImageSignature(hash: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let dynamoDB = AWSDynamoDB.default()
        let item: [String: Any] = [
            AWSConfig.hashFieldName: hash,
            AWSConfig.timestampFieldName: Date().timeIntervalSince1970,
            AWSConfig.ttlFieldName: Date().timeIntervalSince1970 + AWSConfig.defaultTTL
        ]
        
        let request = AWSDynamoDBPutItemInput()
        request.tableName = AWSConfig.dynamoDbTableName
        request.item = item
        
        dynamoDB.putItem(request) { response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            completion(.success(()))
        }
    }
    
    func checkImageSignature(hash: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let dynamoDB = AWSDynamoDB.default()
        let request = AWSDynamoDBGetItemInput()
        request.tableName = AWSConfig.dynamoDbTableName
        request.key = [AWSConfig.hashFieldName: hash]
        
        dynamoDB.getItem(request) { response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            let isDuplicate = response?.item != nil
            completion(.success(isDuplicate))
        }
    }
    
    // MARK: - Image Tagging
    
    func getImageTag(imageURL: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(AWSConfig.getTagApiGatewayEndpoint)?imageURL=\(imageURL)") else {
            completion(.failure(NSError(domain: "AWSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(AWSConfig.getTagApiKey, forHTTPHeaderField: "x-api-key")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag"] as? String else {
                completion(.failure(NSError(domain: "AWSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
                return
            }
            
            completion(.success(tag))
        }
        
        task.resume()
    }
} 
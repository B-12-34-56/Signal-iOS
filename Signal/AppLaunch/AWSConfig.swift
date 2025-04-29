// AWSConfig.swift
// Make sure this file is added to your Signal target

import Foundation
import AWSCore
import AWSCognitoIdentityProvider  // ensure your Podfile/SPM includes these
import AWSDynamoDB

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
        return provider.identityId != nil
    }
}

// MARK: — DynamoDB table helper

extension AWSConfig {
    /// The name of your existing DynamoDB table
    static let dynamoDbTableName = "ImageSignatures"

    /// Check for—and optionally create—the DynamoDB table.
    static func ensureDynamoDbTableExists(createIfNotExists: Bool) async -> Bool {
        let client = AWSDynamoDB.default()

        // 1) Try to describe the table
        let describeInput = AWSDynamoDBDescribeTableInput()!
        describeInput.tableName = dynamoDbTableName

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                client.describeTable(describeInput) { output, error in
                    if let output = output {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: error!)
                    }
                }
            }
            // Table exists
            return true

        } catch let nsError as NSError
          where nsError.domain == AWSDynamoDBErrorDomain
         && nsError.code == AWSDynamoDBErrorType.resourceNotFound.rawValue
        {
            // 2) Table not found
            guard createIfNotExists else { return false }

            // 3) Create it with the same key schema you saw in the console
            // 3) Create it with the same key schema you saw in the console
            let createInput = AWSDynamoDBCreateTableInput()!
            createInput.tableName = dynamoDbTableName

            // ── attributeDefinitions ────────────────────────────────
            let attr = AWSDynamoDBAttributeDefinition()!
            attr.attributeName  = "signature"
            attr.attributeType  = .S         // .s = String

            // ── keySchema ───────────────────────────────────────────
            let key = AWSDynamoDBKeySchemaElement()!
            key.attributeName = "signature"
            key.keyType       = .hash         // partition key

            createInput.attributeDefinitions = [attr]
            createInput.keySchema            = [key]

            // ── provisionedThroughput ───────────────────────────────
            let throughput = AWSDynamoDBProvisionedThroughput()!
            throughput.readCapacityUnits  = 5
            throughput.writeCapacityUnits = 5
            createInput.provisionedThroughput = throughput
            

            do {
                _ = try await withCheckedThrowingContinuation { continuation in
                    client.createTable(createInput) { output, error in
                        if let output = output {
                            continuation.resume(returning: output)
                        } else {
                            continuation.resume(throwing: error!)
                        }
                    }
                }
                return true
            } catch {
                return false
            }
        } catch {
            // Some other error (e.g. permissions/network)
            return false
        }
    }
}

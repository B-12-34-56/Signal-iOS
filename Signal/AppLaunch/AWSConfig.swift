// AWSConfig.swift
// Make sure this file is added to your Signal target

import Foundation
import AWSCore
import AWSCognitoIdentityProvider
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

    /// Quickly check and fetch the identityId if needed
    static func validateAWSCredentials() async -> Bool {
        guard let provider = AWSServiceManager
                .default()
                .defaultServiceConfiguration?
                .credentialsProvider as? AWSCognitoCredentialsProvider
        else {
            return false
        }

        // Already fetched?
        if provider.identityId != nil {
            return true
        }

        // Otherwise actually fetch
        do {
            let fetchedId = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String, Error>) in        // 👈 explicit type
                provider.getIdentityId().continueWith { task in
                    if let error = task.error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: (task.result as? String) ?? "")
                    }
                    return nil
                }
            }


            return !fetchedId.isEmpty
        } catch {
            NSLog("[AWS Init] ⚠️ Error fetching identity: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: — DynamoDB table helper
extension AWSConfig {
    /// Your DynamoDB table name
    static let dynamoDbTableName = "ImageSignatures"

    /// Describe (or create) your table
    static func ensureDynamoDbTableExists(createIfNotExists: Bool) async -> Bool {
        let client = AWSDynamoDB.default()

        // 1) Try describe
        let descInput = AWSDynamoDBDescribeTableInput()!
        descInput.tableName = dynamoDbTableName

        do {
            _ = try await withCheckedThrowingContinuation { cont in
                client.describeTable(descInput) { output, error in
                    if let output = output {
                        cont.resume(returning: output)
                    } else {
                        cont.resume(throwing: error!)
                    }
                }
            }
            return true
        } catch let nsError as NSError
          where nsError.domain == AWSDynamoDBErrorDomain
             && nsError.code == AWSDynamoDBErrorType.resourceNotFound.rawValue
        {
            guard createIfNotExists else { return false }

            // 2) Build CreateTableInput
            let createInput = AWSDynamoDBCreateTableInput()!
            createInput.tableName = dynamoDbTableName

            let attr = AWSDynamoDBAttributeDefinition()!
            attr.attributeName = "signature"
            attr.attributeType = .S

            let key = AWSDynamoDBKeySchemaElement()!
            key.attributeName = "signature"
            key.keyType = .hash

            createInput.attributeDefinitions = [attr]
            createInput.keySchema = [key]

            let throughput = AWSDynamoDBProvisionedThroughput()!
            throughput.readCapacityUnits = 5
            throughput.writeCapacityUnits = 5
            createInput.provisionedThroughput = throughput

            // 3) Create
            do {
                _ = try await withCheckedThrowingContinuation { cont in
                    client.createTable(createInput) { output, error in
                        if let output = output {
                            cont.resume(returning: output)
                        } else {
                            cont.resume(throwing: error!)
                        }
                    }
                }
                return true
            } catch {
                return false
            }
        } catch {
            return false
        }
    }
}

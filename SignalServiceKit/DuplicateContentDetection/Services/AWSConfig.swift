import Foundation

// MARK: - AWSConfig

public enum AWSConfig {
    // AWS Regions
    public static let region = "<YOUR_AWS_REGION>" // e.g., "us-west-2"
    
    // Service endpoints
    public static let apiGatewayEndpoint = "<YOUR_API_GATEWAY_ENDPOINT>" // e.g., "https://api-gateway.example.com"
    public static let dynamoDBEndpoint = "<YOUR_DYNAMODB_ENDPOINT>" // e.g., "https://dynamodb.us-west-2.amazonaws.com"
    public static let cognitoEndpoint = "<YOUR_COGNITO_ENDPOINT>" // e.g., "https://cognito-identity.us-west-2.amazonaws.com"
    
    // Table names
    public static let hashTableName = "SignatureHashes"
    
    // Feature flags
    public static let checkHash = true
    public static let storeHash = true
    public static let deleteHash = true
    
    // Timeouts and retries
    public static let requestTimeoutSeconds: TimeInterval = 30
    public static let maxRetries = 3
    
    // Batch processing
    public static let maxBatchSize = 100
    
    // Authentication
    public static let cognitoIdentityPoolId = "<YOUR_COGNITO_IDENTITY_POOL_ID>" // e.g., "us-west-2:example-identity-pool-id"
    
    // Roles 
    public static let authenticatedRoleArn = "<YOUR_AUTHENTICATED_ROLE_ARN>" // e.g., "arn:aws:iam::123456789012:role/authenticated-role"
    public static let unauthenticatedRoleArn = "<YOUR_UNAUTHENTICATED_ROLE_ARN>" // e.g., "arn:aws:iam::123456789012:role/unauthenticated-role"
}

// MARK: - AWS Error Types

public enum AWSDynamoDBErrorType: String, Error {
    case accessDenied = "AccessDeniedException"
    case conditionalCheckFailed = "ConditionalCheckFailedException"
    case provisionedThroughputExceeded = "ProvisionedThroughputExceededException"
    case resourceInUse = "ResourceInUseException"
    case resourceNotFound = "ResourceNotFoundException"
    case throttlingException = "ThrottlingException"
    case validationError = "ValidationException"
    case internalServerError = "InternalServerError"
    case unknown = "UnknownException"
}

public enum AWSCognitoIdentityErrorType: String, Error {
    case notAuthorized = "NotAuthorizedException"
    case invalidParameter = "InvalidParameterException"
    case resourceNotFound = "ResourceNotFoundException"
    case tooManyRequestsException = "TooManyRequestsException"
    case internalErrorException = "InternalErrorException"
    case limitExceededException = "LimitExceededException"
}

public enum AWSServiceErrorType: String, Error {
    case accessDenied = "AccessDeniedException"
    case throttlingException = "ThrottlingException"
    case serviceUnavailable = "ServiceUnavailableException"
    case validationError = "ValidationException"
    case internalServerError = "InternalServerError"
    case unknown = "UnknownException"
}

// MARK: - Extensions to work with AWS error types
extension AWSDynamoDBErrorType {
    public var isTransient: Bool {
        switch self {
        case .provisionedThroughputExceeded, .throttlingException, .internalServerError:
            return true
        default:
            return false
        }
    }
}

extension AWSCognitoIdentityErrorType {
    public var isTransient: Bool {
        switch self {
        case .tooManyRequestsException, .internalErrorException:
            return true
        default:
            return false
        }
    }
}

extension AWSServiceErrorType {
    public var isTransient: Bool {
        switch self {
        case .throttlingException, .serviceUnavailable, .internalServerError:
            return true
        default:
            return false
        }
    }
}

// MARK: - Error Type Collection Extensions
extension Collection where Element == AWSDynamoDBErrorType {
    public func contains(_ errorType: AWSDynamoDBErrorType) -> Bool {
        self.contains { $0 == errorType }
    }
}

extension Collection where Element == AWSCognitoIdentityErrorType {
    public func contains(_ errorType: AWSCognitoIdentityErrorType) -> Bool {
        self.contains { $0 == errorType }
    }
}

extension Collection where Element == AWSServiceErrorType {
    public func contains(_ errorType: AWSServiceErrorType) -> Bool {
        self.contains { $0 == errorType }
    }
}

// Make optional error types conform to Collection for contains() check
extension Optional: Collection where Wrapped: Error {
    public var startIndex: Int { return 0 }
    public var endIndex: Int { return self != nil ? 1 : 0 }
    
    public subscript(position: Int) -> Wrapped {
        precondition(position == 0 && self != nil)
        return self!
    }
    
    public func index(after i: Int) -> Int {
        precondition(i == 0)
        return 1
    }
    
    public func contains(_ element: Wrapped) -> Bool where Wrapped: Equatable {
        return self == element
    }
} 
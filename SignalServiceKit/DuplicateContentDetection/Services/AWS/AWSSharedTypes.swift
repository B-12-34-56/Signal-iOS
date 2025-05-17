import Foundation
import AWSCore

// MARK: - Shared AWS Types

/// Shared error types for AWS operations
public enum AWSSharedError: Error, LocalizedError {
    case invalidConfiguration
    case connectionTimeout
    case serviceUnavailable
    case unauthorized
    case networkError(Error)
    case internalError(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid AWS configuration"
        case .connectionTimeout:
            return "Connection timed out"
        case .serviceUnavailable:
            return "AWS service is currently unavailable"
        case .unauthorized:
            return "Unauthorized access"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}

/// Shared status types for AWS operations
public enum AWSOperationStatus {
    case pending
    case inProgress
    case completed
    case failed
    case cancelled
}

/// Shared configuration for AWS services
public struct AWSSharedConfig {
    public static let defaultTimeout: TimeInterval = 30
    public static let maxRetryCount: Int = 3
    public static let initialRetryDelay: TimeInterval = 1.0
    public static let maxRetryDelay: TimeInterval = 30.0
    
    public static func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        let baseDelay = min(initialRetryDelay * pow(2.0, Double(attempt)), maxRetryDelay)
        let jitterMultiplier = 0.75 + 0.5 * Double.random(in: 0..<1)
        return max(0.1, baseDelay * jitterMultiplier)
    }
} 
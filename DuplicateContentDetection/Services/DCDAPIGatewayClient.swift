//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import SignalCore
import Logging

/// Client for interacting with AWS API Gateway for duplicate content detection
public final class APIGatewayClient {
    // MARK: - Properties
    
    /// Shared instance for accessing the client throughout the app
    public static let shared = APIGatewayClient()
    
    /// Logger for capturing client operations
    private let logger = Logger(label: "org.signal.APIGatewayClient")
    
    /// Default retry count for API operations
    private let defaultRetryCount = AWSConfig.maxRetryCount
    
    // MARK: - Initialization
    
    /// Private initializer for singleton
    private init() {
        SignalCoreUtility.logDebug("Initialized APIGatewayClient")
    }
    
    // MARK: - Public API
    
    /// Makes a request to the API Gateway with authentication
    /// - Parameters:
    ///   - endpoint: The API endpoint URL
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - apiKey: Optional API key for authentication
    ///   - headers: Additional HTTP headers
    ///   - body: Optional request body as Data
    ///   - queryItems: Optional query parameters
    ///   - retryCount: Maximum number of retry attempts
    /// - Returns: Response data if successful
    public func request(
        endpoint: String,
        method: HTTPMethod = .get,
        apiKey: String? = nil,
        headers: [String: String] = [:],
        body: Data? = nil,
        queryItems: [String: String] = [:],
        retryCount: Int? = nil
    ) async throws -> Data {
        // Create URL with query parameters
        guard var urlComponents = URLComponents(string: endpoint) else {
            logger.error("Invalid endpoint URL: \(endpoint)")
            SignalCoreUtility.logError("Invalid endpoint URL: \(endpoint)")
            throw APIError.invalidURL
        }
        
        if !queryItems.isEmpty {
            urlComponents.queryItems = queryItems.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        
        guard let url = urlComponents.url else {
            logger.error("Failed to construct URL from components")
            SignalCoreUtility.logError("Failed to construct URL from components")
            throw APIError.invalidURL
        }
        
        // Create and configure the request
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        
        // Add headers
        var allHeaders = headers
        if let apiKey = apiKey {
            allHeaders["x-api-key"] = apiKey
        }
        allHeaders["Content-Type"] = "application/json"
        
        for (key, value) in allHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let maxAttempts = retryCount ?? defaultRetryCount
        
        logger.info("Making \(method.rawValue) request to \(url.absoluteString)")
        SignalCoreUtility.logDebug("Making \(method.rawValue) request to \(url.absoluteString)")
        
        // Execute with retry logic
        return try await executeWithRetry(request: request, maxAttempts: maxAttempts)
    }
    
    // MARK: - Private Methods
    
    /// Executes a network request with retry logic
    private func executeWithRetry(request: URLRequest, maxAttempts: Int) async throws -> Data {
        var lastError: Error?
        
        for attempt in 0..<maxAttempts {
            do {
                logger.debug("Request attempt \(attempt + 1)/\(maxAttempts) to \(request.url?.absoluteString ?? "unknown")")
                SignalCoreUtility.logDebug("Request attempt \(attempt + 1)/\(maxAttempts) to \(request.url?.absoluteString ?? "unknown")")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    logger.error("Invalid response type")
                    SignalCoreUtility.logError("Invalid response type")
                    throw APIError.invalidResponse
                }
                
                // Check HTTP status code
                let statusCode = httpResponse.statusCode
                if (200...299).contains(statusCode) {
                    logger.info("Request succeeded with status code \(statusCode)")
                    SignalCoreUtility.logDebug("Request succeeded with status code \(statusCode)")
                    return data
                } else {
                    // Log error response
                    let responseString = String(data: data, encoding: .utf8) ?? "Unable to parse response"
                    logger.warning("Request failed with status code \(statusCode): \(responseString)")
                    SignalCoreUtility.logError("Request failed with status code \(statusCode): \(responseString)")
                    
                    let error = APIError.httpError(statusCode: statusCode, responseData: data)
                    
                    // If error is not retryable or this is the last attempt, throw immediately
                    if !isRetryableStatusCode(statusCode) || attempt == maxAttempts - 1 {
                        throw error
                    }
                    
                    lastError = error
                }
            } catch let error as APIError {
                // Handle API-specific errors
                if attempt < maxAttempts - 1 && error.isRetryable {
                    logger.warning("Retryable API error: \(error.localizedDescription)")
                    lastError = error
                    let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    throw error
                }
            } catch {
                // Handle other errors (like network issues)
                logger.error("Network error: \(error.localizedDescription)")
                SignalCoreUtility.logError("Network error", error: error)
                
                if attempt < maxAttempts - 1 && isRetryableNetworkError(error) {
                    lastError = error
                    let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    throw APIError.networkError(error)
                }
            }
            
            // Wait before retrying
            if attempt < maxAttempts - 1 {
                let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                logger.info("Retrying after \(String(format: "%.2f", delay)) seconds...")
                SignalCoreUtility.logDebug("Retrying after \(String(format: "%.2f", delay)) seconds...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // If we've exhausted retries and have a last error, throw it
        throw lastError ?? APIError.unknown
    }
    
    /// Determines if an HTTP status code should be retried
    private func isRetryableStatusCode(_ statusCode: Int) -> Bool {
        return statusCode == 429 || // Too Many Requests
            statusCode == 503 || // Service Unavailable
            statusCode == 502 || // Bad Gateway
            statusCode == 504    // Gateway Timeout
    }
    
    /// Determines if a network error should be retried
    private func isRetryableNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        
        return nsError.domain == NSURLErrorDomain &&
        (nsError.code == NSURLErrorTimedOut ||
         nsError.code == NSURLErrorCannotConnectToHost ||
         nsError.code == NSURLErrorNetworkConnectionLost ||
         nsError.code == NSURLErrorNotConnectedToInternet)
    }
}

// MARK: - Supporting Types

/// HTTP methods for API requests
public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// Errors that can occur during API operations
public enum APIError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, responseData: Data)
    case networkError(Error)
    case unknown
    
    public static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.invalidResponse, .invalidResponse),
             (.unknown, .unknown):
            return true
        case let (.httpError(statusCode1, _), .httpError(statusCode2, _)):
            return statusCode1 == statusCode2
        case (.networkError, .networkError):
            return true
        default:
            return false
        }
    }
    
    /// Determines if this error type is retryable
    var isRetryable: Bool {
        switch self {
        case .httpError(let statusCode, _):
            return statusCode == 429 || // Too Many Requests
                statusCode == 503 || // Service Unavailable
                statusCode == 502 || // Bad Gateway
                statusCode == 504    // Gateway Timeout
        case .networkError:
            return true
        case .invalidURL, .invalidResponse, .unknown:
            return false
        }
    }
} 
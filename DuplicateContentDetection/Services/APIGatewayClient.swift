//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import AWSCore
import AWSAPIGateway
import Logging

/// Client for interacting with AWS API Gateway endpoints with authentication, retries and error handling.
public final class APIGatewayClient {
    
    // MARK: - Constants
    
    /// Error domain for API Gateway errors
    public static let errorDomain = "APIGatewayClientErrorDomain"
    
    /// Key for HTTP status code in error user info dictionary
    public static let HTTPStatusCodeErrorKey = "HTTPStatusCode"
    
    /// HTTP status codes
    public enum HTTPStatusCode: Int {
        case ok = 200
        case created = 201
        case accepted = 202
        case noContent = 204
        case badRequest = 400
        case unauthorized = 401
        case forbidden = 403
        case notFound = 404
        case conflict = 409
        case tooManyRequests = 429
        case internalServerError = 500
        case serviceUnavailable = 503
        case gatewayTimeout = 504
        
        var isSuccess: Bool {
            return (200...299).contains(rawValue)
        }
        
        var isRetryable: Bool {
            switch self {
            case .tooManyRequests, .internalServerError, .serviceUnavailable, .gatewayTimeout:
                return true
            default:
                return false
            }
        }
    }
    
    // MARK: - Properties
    
    /// Shared singleton instance
    public static let shared = APIGatewayClient()
    
    private let logger = Logger(label: "org.signal.APIGatewayClient")
    private let defaultRetryCount = 3
    private let session: URLSession
    
    // MARK: - Initialization
    
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = AWSConfig.requestTimeoutInterval
        config.timeoutIntervalForResource = AWSConfig.resourceTimeoutInterval
        self.session = URLSession(configuration: config)
        logger.info("Initialized APIGatewayClient")
    }
    
    // MARK: - Public Methods
    
    /// Makes a GET request to the API Gateway
    /// - Parameters:
    ///   - path: The API path to request
    ///   - endpointUrl: Base endpoint URL for the request
    ///   - retryCount: Number of retries on failure (default: 3)
    /// - Returns: Decoded response of type T
    /// - Throws: Network or decoding errors
    public func get<T: Decodable>(
        path: String,
        endpointUrl: String,
        retryCount: Int = 3
    ) async throws -> T {
        return try await makeRequest(
            method: "GET",
            path: path,
            endpointUrl: endpointUrl,
            retryCount: retryCount
        )
    }
    
    /// Makes a POST request to the API Gateway
    /// - Parameters:
    ///   - path: The API path to request
    ///   - body: Optional body data to send
    ///   - endpointUrl: Base endpoint URL for the request
    ///   - retryCount: Number of retries on failure (default: 3)
    /// - Returns: Decoded response of type T
    /// - Throws: Network or decoding errors
    public func post<T: Decodable>(
        path: String,
        body: Any? = nil,
        endpointUrl: String,
        retryCount: Int = 3
    ) async throws -> T {
        return try await makeRequest(
            method: "POST",
            path: path,
            body: body,
            endpointUrl: endpointUrl,
            retryCount: retryCount
        )
    }
    
    /// Makes a PUT request to the API Gateway
    /// - Parameters:
    ///   - path: The API path to request
    ///   - body: Optional body data to send
    ///   - endpointUrl: Base endpoint URL for the request
    ///   - retryCount: Number of retries on failure (default: 3)
    /// - Returns: Decoded response of type T
    /// - Throws: Network or decoding errors
    public func put<T: Decodable>(
        path: String,
        body: Any? = nil,
        endpointUrl: String,
        retryCount: Int = 3
    ) async throws -> T {
        return try await makeRequest(
            method: "PUT",
            path: path,
            body: body,
            endpointUrl: endpointUrl,
            retryCount: retryCount
        )
    }
    
    /// Makes a DELETE request to the API Gateway
    /// - Parameters:
    ///   - path: The API path to request
    ///   - endpointUrl: Base endpoint URL for the request
    ///   - retryCount: Number of retries on failure (default: 3)
    /// - Returns: Decoded response of type T
    /// - Throws: Network or decoding errors
    public func delete<T: Decodable>(
        path: String,
        endpointUrl: String,
        retryCount: Int = 3
    ) async throws -> T {
        return try await makeRequest(
            method: "DELETE",
            path: path,
            endpointUrl: endpointUrl,
            retryCount: retryCount
        )
    }
    
    // MARK: - Private Methods
    
    /// Makes an HTTP request with retry logic
    private func makeRequest<T: Decodable>(
        method: String,
        path: String,
        body: Any? = nil,
        endpointUrl: String,
        retryCount: Int
    ) async throws -> T {
        // Build the URL
        guard let baseURL = URL(string: endpointUrl),
              let url = URL(string: path, relativeTo: baseURL) else {
            throw NSError(
                domain: Self.errorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(endpointUrl)\(path)"]
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        // Add headers from AWSConfig
        let headers = AWSConfig.getAPIGatewayHeaders(for: endpointUrl)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Add body if provided
        if let body = body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw NSError(
                    domain: Self.errorDomain,
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to serialize request body: \(error.localizedDescription)"]
                )
            }
        }
        
        // Execute request with retries
        var lastError: Error?
        for attempt in 0..<max(1, retryCount) {
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(
                        domain: Self.errorDomain,
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]
                    )
                }
                
                // Handle response based on status code
                let statusCode = HTTPStatusCode(rawValue: httpResponse.statusCode) ?? .internalServerError
                
                if statusCode.isSuccess {
                    // For EmptyResponse type, return empty instance if no content
                    if T.self == EmptyResponse.self {
                        return EmptyResponse() as! T
                    }
                    
                    // For other types, try to decode response
                    do {
                        return try JSONDecoder().decode(T.self, from: data)
                    } catch {
                        throw NSError(
                            domain: Self.errorDomain,
                            code: -4,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Failed to decode response: \(error.localizedDescription)",
                                Self.HTTPStatusCodeErrorKey: httpResponse.statusCode
                            ]
                        )
                    }
                } else {
                    // Create error with status code
                    let error = NSError(
                        domain: Self.errorDomain,
                        code: httpResponse.statusCode,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Request failed with status code \(httpResponse.statusCode)",
                            Self.HTTPStatusCodeErrorKey: httpResponse.statusCode
                        ]
                    )
                    
                    // Check if we should retry
                    if statusCode.isRetryable && attempt < retryCount - 1 {
                        lastError = error
                        let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                        logger.info("Request failed (attempt \(attempt + 1)/\(retryCount)). Retrying in \(String(format: "%.2f", delay))s...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    
                    throw error
                }
            } catch {
                lastError = error
                
                // Check if we should retry network errors
                if (error as NSError).domain == NSURLErrorDomain && attempt < retryCount - 1 {
                    let delay = AWSConfig.calculateBackoffDelay(attempt: attempt)
                    logger.info("Network error (attempt \(attempt + 1)/\(retryCount)). Retrying in \(String(format: "%.2f", delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                throw error
            }
        }
        
        throw lastError ?? NSError(
            domain: Self.errorDomain,
            code: -5,
            userInfo: [NSLocalizedDescriptionKey: "Request failed after \(retryCount) attempts"]
        )
    }
}

// MARK: - Supporting Types

/// Empty response type for endpoints that return no content
public struct EmptyResponse: Decodable {}
//
//  ContentFilterTypes.swift
//  SignalServiceKit
//
//  Created for content filtering shared types
//

import Foundation

/// Result type for content filtering operations
public enum FilterResult {
    /// Content passed all filters
    case allowed
    
    /// Content was blocked
    /// - Parameters:
    ///   - reason: Human-readable reason for blocking
    ///   - tags: Array of filter tags that triggered the block
    case blocked(reason: String, tags: [String])
    
    /// Filter operation failed
    /// - Parameter error: The underlying error
    case error(Error)
}

// Add any other shared types here
public struct FilterConfiguration {
    public let enabled: Bool
    public let strictMode: Bool
    
    public init(enabled: Bool = true, strictMode: Bool = false) {
        self.enabled = enabled
        self.strictMode = strictMode
    }
} 
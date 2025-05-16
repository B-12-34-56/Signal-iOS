//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import os.log

/// Utility class for Signal core functionality
public struct SignalCoreUtility {
    
    // MARK: - Logging
    
    /// OS log object for system logging
    private static let osLog = OSLog(subsystem: "org.signal.SignalCore", category: "SignalCore")
    
    /// Log levels for different types of logging
    public enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case critical = "CRITICAL"
    }
    
    /// Logs a debug message
    /// - Parameter message: The message to log
    public static func logDebug(_ message: String) {
        log(message, level: .debug)
    }
    
    /// Logs an info message
    /// - Parameter message: The message to log
    public static func logInfo(_ message: String) {
        log(message, level: .info)
    }
    
    /// Logs a warning message
    /// - Parameter message: The message to log
    public static func logWarning(_ message: String) {
        log(message, level: .warning)
    }
    
    /// Logs an error message
    /// - Parameters:
    ///   - message: The message to log
    ///   - error: Optional error to include in the log
    public static func logError(_ message: String, error: Error? = nil) {
        if let error = error {
            log("\(message): \(error.localizedDescription)", level: .error)
        } else {
            log(message, level: .error)
        }
    }
    
    /// Logs a critical message
    /// - Parameters:
    ///   - message: The message to log
    ///   - error: Optional error to include in the log
    public static func logCritical(_ message: String, error: Error? = nil) {
        if let error = error {
            log("\(message): \(error.localizedDescription)", level: .critical)
        } else {
            log(message, level: .critical)
        }
    }
    
    /// Core logging function
    /// - Parameters:
    ///   - message: Message to log
    ///   - level: Log level
    private static func log(_ message: String, level: LogLevel) {
        let formattedMessage = "[\(level.rawValue)] \(message)"
        
        // Print to console for debug builds
        #if DEBUG
        print(formattedMessage)
        #endif
        
        // Also log to system log
        switch level {
        case .debug:
            os_log("%{public}@", log: osLog, type: .debug, formattedMessage)
        case .info:
            os_log("%{public}@", log: osLog, type: .info, formattedMessage)
        case .warning:
            os_log("%{public}@", log: osLog, type: .default, formattedMessage)
        case .error:
            os_log("%{public}@", log: osLog, type: .error, formattedMessage)
        case .critical:
            os_log("%{public}@", log: osLog, type: .fault, formattedMessage)
        }
    }
    
    // MARK: - Version Utilities
    
    /// Gets the current app version
    /// - Returns: String representing the app version
    public static func appVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "Unknown"
    }
    
    /// Gets the current app build number
    /// - Returns: String representing the app build
    public static func appBuild() -> String {
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return build
        }
        return "Unknown"
    }
    
    /// Gets the combined app version and build
    /// - Returns: String of version and build
    public static func appVersionAndBuild() -> String {
        return "\(appVersion()) (\(appBuild()))"
    }
    
    // MARK: - Device Information
    
    /// Gets the model name of the current device
    /// - Returns: String with the model name
    public static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let modelCode = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                ptr in String(validatingUTF8: ptr)
            }
        }
        return modelCode ?? "Unknown"
    }
    
    /// Gets the system version
    /// - Returns: Current iOS version
    public static func systemVersion() -> String {
        return UIDevice.current.systemVersion
    }
} 
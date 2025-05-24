// AWSTask+Async.swift
// Shared async/await extension for AWSTask
import Foundation

/*
extension AWSTask {
    /// Converts an AWSTask to a Swift Concurrency async/await operation.
    /// - Returns: The result of the task.
    /// - Throws: Any error the task encountered.
    func aws_await<Result>() async throws -> Result {
        return try await withCheckedThrowingContinuation { continuation in
            self.continueWith { task -> Void in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else if let exception = task.exception {
                    // Convert NSException to NSError
                    continuation.resume(throwing: NSError(
                        domain: "AWSTaskException",
                        code: 0, // Use a specific code or map exception type
                        userInfo: [NSLocalizedDescriptionKey: "Task threw exception: \(exception)"]
                    ))
                } else if task.isCancelled {
                     continuation.resume(throwing: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                } else if let result = task.result as? Result {
                    continuation.resume(returning: result)
                } else if Result.self == Void.self {
                     // Handle Void result case, common for operations like putObject, deleteObject, headObject
                     continuation.resume(returning: () as! Result)
                } else {
                    // If result type doesn't match and isn't Void
                    continuation.resume(throwing: NSError(
                        domain: "AWSTaskError",
                        code: 0, // Use a specific code
                        userInfo: [NSLocalizedDescriptionKey: "Task completed with incompatible result type \(type(of: task.result)) when expecting \(Result.self) or Void."]
                    ))
                }
            }
        }
    }
}
*/ 
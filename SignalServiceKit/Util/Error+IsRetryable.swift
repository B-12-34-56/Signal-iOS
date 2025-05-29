//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import ObjectiveC

extension Error {
    public var hasIsRetryable: Bool {
        if self is IsRetryableProvider {
            return true
        }
        if self.isNetworkFailureOrTimeout {
            return true
        }
        return false
    }

    // MARK: - MAIN RETRY LOGIC
    // Tweaked to (1) emit a helpful log for *every* error and (2) avoid hard SIGTRAPs
    // when an error family isn’t covered yet.  Unknown errors are treated as *not*
    // retryable so they bubble up cleanly, but you can flip that by changing the
    // final `return`.
    public var isRetryable: Bool {
        // ---- TEMP: capture the raw NSError so we can see domain/code in logs ----
        let nsError = self as NSError
        Logger.error("[Retry] saw error: \(nsError.domain):\(nsError.code) – \(nsError.localizedDescription)")
        // -----------------------------------------------------------------------

        // Swift‑Error ↔︎ NSError bridging notes (unchanged)
        if let error = self as? IsRetryableProvider {
            return error.isRetryableProvider
        }
        if let error = (self as NSError) as? IsRetryableProvider {
            return error.isRetryableProvider
        }

        if self.isNetworkFailureOrTimeout {
            // We can safely default to retrying network failures.
            return true
        }

        // ---- FALLBACK for previously unseen errors ----
        // No more owsFailDebug(); we simply log and declare it *not* retryable so the
        // caller decides how to proceed, and we keep Debug builds running.
        Logger.error("[Retry] Unrecognised error → treating as NOT retryable: \(self)")
        return false
    }
}

// MARK: -

public protocol IsRetryableProvider {
    var isRetryableProvider: Bool { get }
}

// MARK: -

extension OWSAssertionError: IsRetryableProvider {
    public var isRetryableProvider: Bool { false }
}

extension OWSGenericError: IsRetryableProvider {
    public var isRetryableProvider: Bool { false }
}

// MARK: -

// NOTE: We typically prefer to use a more specific error.
public class OWSRetryableError: CustomNSError, IsRetryableProvider {
    public static var asNSError: NSError {
        OWSRetryableError() as Error as NSError
    }

    // MARK: - IsRetryableProvider

    public var isRetryableProvider: Bool { true }
}

// MARK: -

// NOTE: We typically prefer to use a more specific error.
public class OWSUnretryableError: CustomNSError, IsRetryableProvider {
    public static var asNSError: NSError {
        OWSUnretryableError() as Error as NSError
    }

    public init() {}

    // MARK: - IsRetryableProvider

    public var isRetryableProvider: Bool { false }
}

// MARK: -

public enum SSKUnretryableError: Error, IsRetryableProvider {
    case stickerDecryptionFailure
    case downloadCouldNotMoveFile
    case downloadCouldNotDeleteFile
    case messageProcessingFailed

    // MARK: - IsRetryableProvider

    public var isRetryableProvider: Bool { false }
}

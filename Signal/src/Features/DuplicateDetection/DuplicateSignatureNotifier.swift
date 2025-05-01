// DuplicateSignatureNotifier.swift
// Shows a one-shot alert or banner whenever a duplicate is detected.

import UIKit

final class DuplicateSignatureNotifier: DuplicateSignatureStoreDelegate {

    /// Create exactly one shared instance and set it as the store’s delegate.
    static let shared = DuplicateSignatureNotifier()   // install from AppDelegate

    private init() {}

    // MARK: - DuplicateSignatureStoreDelegate
    func didDetectDuplicate(attachmentId: String,
                            signature: String,
                            originalSender: String) {

        // Craft a human message
        let body = originalSender == "(already sent)"
            ? "This photo has already been shared in this conversation."
            : "This photo is identical to one that \(originalSender) already sent."

        // Present a simple alert on the *front-most* view controller
        DispatchQueue.main.async {
            guard let root = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } })
                    .first?.rootViewController else { return }

            let alert = UIAlertController(title: "Duplicate image blocked",
                                          message: body,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            root.present(alert, animated: true)
        }
    }
}
//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//


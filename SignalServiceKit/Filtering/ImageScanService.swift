//
//  ImageScanService.swift
//  SignalServiceKit
//

import Foundation
import UIKit            // fine here because SignalServiceKit is iOS-only

public enum ImageScanVerdict {
    case allowed
    case blocked
    case error
}

public final class ImageScanService {

    public static let shared = ImageScanService()
    private init() {}

    /// Very simple placeholder. Replace with your real scanning logic.
    public func scan(imageURL: URL) async throws -> ImageScanVerdict {
        // Just confirm we can load the file as an image.
        guard UIImage(contentsOfFile: imageURL.path) != nil else {
            return .error
        }
        return .allowed
    }
} 
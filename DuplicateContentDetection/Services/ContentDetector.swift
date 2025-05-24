import Foundation
import CryptoKit
import UIKit

struct ContentDetector {
    /// Compute a SHA-256 hash for the given image data and return it as a lowercase hex string.
    static func computeImageHash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Determine the appropriate file extension for an image from its data or UIImage.
    static func determineImageExtension(for image: UIImage, data: Data) -> String {
        // If the data represents a PNG (has PNG header), use "png"
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { // PNG magic number
            return "png"
        }
        // Check JPEG magic numbers (0xFF, 0xD8)
        if data.starts(with: [0xFF, 0xD8]) {
            return "jpg"
        }
        // If neither, fallback to png if image has alpha, else jpg
        if let cgImage = image.cgImage, cgImage.alphaInfo != .none {
            return "png"
        }
        return "jpg"
    }
} 
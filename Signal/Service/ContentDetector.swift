import CryptoKit
import UIKit

struct ContentDetector {
    static func computeImageHash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func determineImageExtension(for image: UIImage, data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" } // PNG magic number
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" } // JPEG magic number
        return "jpg"
    }
} 
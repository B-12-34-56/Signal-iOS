import CryptoKit
import UIKit

struct ContentDetector {
    static func computeImageHash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func determineImageExtension(for image: UIImage, data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        // Add more formats as needed (gif, webp, heic, etc.)
        if let cgImage = image.cgImage, cgImage.alphaInfo != .none { return "png" }
        return "jpg"
    }
} 
import CryptoKit
import UIKit

struct ContentDetector {
    static func computeImageHash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

<<<<<<< HEAD
    static func determineImageExtension(for image: UIImage, data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        // Add more formats as needed (gif, webp, heic, etc.)
        if let cgImage = image.cgImage, cgImage.alphaInfo != .none { return "png" }
=======
    static func determineImageExtension(from data: Data) -> String {
        guard data.count > 12 else { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) && data[8...11].starts(with: [0x57, 0x45, 0x42, 0x50]) { return "webp" }
        if data.count > 12, data[4...7].starts(with: [0x66, 0x74, 0x79, 0x70]) {
            if data[8...11].starts(with: [0x68, 0x65, 0x69, 0x63]) || data[8...11].starts(with: [0x68, 0x65, 0x69, 0x78]) {
                return "heic"
            }
        }
>>>>>>> origin/Ibrahim
        return "jpg"
    }
} 
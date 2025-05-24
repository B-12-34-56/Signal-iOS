import Foundation
import CryptoKit
import UIKit
import CocoaImageHashing

public final class ImageHashing {
    public static let shared = ImageHashing()
    private init() {}
    
    // MARK: - SHA-256 Hashing
    
    public func sha256Hash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Perceptual Hashing
    
    public func perceptualHash(image: UIImage) -> String? {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        let hashValue = OSImageHashing.sharedInstance()
                        .hashImageData(jpeg, with: .pHash)
        return String(format: "%016llx", hashValue)
    }
    
    // MARK: - Combined Hashing
    
    public func computeHashes(for image: UIImage) -> (sha256Hash: String, perceptualHash: String?)? {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        let shaHex = sha256Hash(data: jpeg)
        let pHash  = perceptualHash(image: image)
        return (shaHex, pHash)
    }
} 
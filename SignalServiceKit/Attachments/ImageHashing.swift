import Foundation
import CryptoKit
import UIKit
import CocoaImageHashing

@objc
public class ImageHashing: NSObject {
    @objc
    public static let shared = ImageHashing()
    
    private override init() {
        super.init()
    }
    
    // MARK: - SHA-256 Hashing
    
    @objc
    public func sha256Hash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Perceptual Hashing
    
    @objc
    public func perceptualHash(image: UIImage) -> String? {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            Logger.error("ImageHashing: Failed to convert image to JPEG data")
            return nil
        }
        
        let phashData = OSImageHashing.sharedInstance().hashImageData(imageData, with: .pHash)
        return phashData.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Combined Hashing
    
    @objc
    public func computeHashes(for image: UIImage) -> (sha256Hash: String, perceptualHash: String?)? {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            Logger.error("ImageHashing: Failed to convert image to JPEG data")
            return nil
        }
        
        let sha256Hash = self.sha256Hash(data: imageData)
        let perceptualHash = self.perceptualHash(image: image)
        
        return (sha256Hash, perceptualHash)
    }
} 
import Foundation
import CryptoKit

public final class ImageHasher {
    public static let shared = ImageHasher()
    
    private init() {}
    
    /// Computes a SHA-256 hash of the image data
    /// - Parameter imageData: The raw image data to hash
    /// - Returns: A 32-byte Data object containing the hash
    public func hash(_ imageData: Data) -> Data {
        let hash = SHA256.hash(data: imageData)
        return Data(hash)
    }
    
    /// Computes a SHA-256 hash of the image data and returns it as a hex string
    /// - Parameter imageData: The raw image data to hash
    /// - Returns: A hex string representation of the hash
    public func hashHex(_ imageData: Data) -> String {
        let hash = SHA256.hash(data: imageData)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
} 
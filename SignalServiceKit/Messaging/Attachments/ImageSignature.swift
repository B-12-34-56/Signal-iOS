import Foundation
import CryptoKit

enum ImageSignature {
    static func sha256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
} 
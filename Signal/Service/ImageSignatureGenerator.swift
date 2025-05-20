import Foundation
import UIKit
import CommonCrypto
import CoreImage

class ImageSignatureGenerator {
    static let shared = ImageSignatureGenerator()
    
    private init() {}
    
    func generateSignature(for image: UIImage) -> String? {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            return nil
        }
        
        // Generate SHA-256 hash of the image data
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        imageData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        
        // Convert hash to hex string
        let hashString = hash.map { String(format: "%02x", $0) }.joined()
        return hashString
    }
    
    static func generatePerceptualHash(for img: UIImage) -> String? {
        guard let cg = img.cgImage else { return nil }
        let ctx = CIContext()
        let ci = CIImage(cgImage: cg)
        let eight = ci.transformed(by: .init(scaleX: 8/ci.extent.width,
                                           y: 8/ci.extent.height))
        guard let out = ctx.createCGImage(eight, from: eight.extent) else { return nil }
        var bits: UInt64 = 0
        var avg: UInt64 = 0
        var pixels = [UInt8](repeating: 0, count: 64)
        let cf = CFDataGetBytePtr(out.dataProvider!.data)!
        for i in 0..<64 { pixels[i] = cf[i*4] ; avg += UInt64(pixels[i]) }
        avg /= 64
        for i in 0..<64 where pixels[i] > avg { bits |= 1 << i }
        return String(format: "%016llx", bits)
    }
} 
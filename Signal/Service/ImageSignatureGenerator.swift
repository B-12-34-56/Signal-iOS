import Foundation
import UIKit
import CommonCrypto

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
    
    func generatePerceptualHash(for image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }
        
        // Resize image to 8x8 for perceptual hash
        let size = CGSize(width: 8, height: 8)
        UIGraphicsBeginImageContext(size)
        image.draw(in: CGRect(origin: .zero, size: size))
        guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()
        
        // Convert to grayscale
        guard let grayscaleImage = resizedImage.cgImage else { return nil }
        
        // Calculate average pixel value
        var totalValue: UInt32 = 0
        let width = grayscaleImage.width
        let height = grayscaleImage.height
        let bytesPerRow = width
        let totalBytes = bytesPerRow * height
        
        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        
        context?.draw(grayscaleImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        for pixel in pixelData {
            totalValue += UInt32(pixel)
        }
        
        let averageValue = totalValue / UInt32(totalBytes)
        
        // Generate hash based on pixel values compared to average
        var hash = ""
        for pixel in pixelData {
            hash += pixel > UInt8(averageValue) ? "1" : "0"
        }
        
        return hash
    }
} 
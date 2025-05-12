import Foundation
import CryptoKit

/// Generates and compares perceptual hashes for images
public class ImageHasher {
    public static let shared = ImageHasher()
    
    private init() {}
    
    public func hash(_ data: Data) -> (hash: Data, hexString: String) {
        let hash = SHA256.hash(data: data)
        let hashData = Data(hash)
        let hexString = hashData.map { String(format: "%02x", $0) }.joined()
        return (hashData, hexString)
    }
    
    public func hash(_ url: URL) throws -> (hash: Data, hexString: String) {
        let data = try Data(contentsOf: url)
        return hash(data)
    }
    
    private static let hashSize = 16 // 16x16 image for hash calculation
    
    /// Calculates a perceptual hash for an image
    static func calculateImageHash(from imageURL: URL) -> String? {
        guard let image = UIImage(contentsOfFile: imageURL.path) else {
            Logger.debug("Failed to load image from \(imageURL.path)")
            return nil
        }
        
        // Resize image to small dimensions for hashing
        guard let scaledImage = resizeImage(image, to: CGSize(width: hashSize, height: hashSize)) else {
            return nil
        }
        
        // Convert to grayscale and calculate average
        guard let pixelData = getPixelData(from: scaledImage) else {
            return nil
        }
        
        // Calculate grayscale values and average
        var grayPixels = [Int]()
        var totalGray: Int = 0
        
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let r = Int(pixelData[i])
            let g = Int(pixelData[i + 1])
            let b = Int(pixelData[i + 2])
            
            // Simple grayscale conversion
            let gray = (r + g + b) / 3
            grayPixels.append(gray)
            totalGray += gray
        }
        
        let avgGray = totalGray / grayPixels.count
        
        // Generate hash (1 if above average, 0 if below)
        var binaryHash = ""
        for grayValue in grayPixels {
            binaryHash += grayValue >= avgGray ? "1" : "0"
        }
        
        return convertBinaryHashToHex(binaryHash)
    }
    
    /// Calculates the Hamming distance between two image hashes
    static func getHashDistance(_ hash1: String, _ hash2: String) -> Int {
        guard hash1.count == hash2.count else {
            return -1 // Invalid comparison
        }
        
        let hash1Chars = Array(hash1)
        let hash2Chars = Array(hash2)
        
        var distance = 0
        for i in 0..<hash1Chars.count {
            if hash1Chars[i] != hash2Chars[i] {
                distance += 1
            }
        }
        
        return distance
    }
    
    /// Determines if two images are perceptually similar based on hash distance
    static func areImagesSimilar(_ hash1: String, _ hash2: String, threshold: Int) -> Bool {
        let distance = getHashDistance(hash1, hash2)
        return distance >= 0 && distance <= threshold
    }
    
    // MARK: - Helper Methods
    
    /// Resize an image to specified dimensions
    private static func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resizedImage
    }
    
    /// Extract raw pixel data from an image
    private static func getPixelData(from image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        let bitsPerComponent = 8
        let bytesPerRow = 4 * width
        let totalBytes = bytesPerRow * height
        
        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return pixelData
    }
    
    /// Convert binary hash to hex for storage efficiency
    private static func convertBinaryHashToHex(_ binaryHash: String) -> String {
        var hexHash = ""
        
        // Process in 4-bit chunks
        var i = 0
        while i < binaryHash.count {
            let endIndex = min(i + 4, binaryHash.count)
            let startIndex = binaryHash.index(binaryHash.startIndex, offsetBy: i)
            let endIndexPos = binaryHash.index(binaryHash.startIndex, offsetBy: endIndex)
            let chunk = binaryHash[startIndex..<endIndexPos]
            
            if let decimal = Int(String(chunk), radix: 2) {
                hexHash += String(format: "%X", decimal)
            }
            
            i += 4
        }
        
        return hexHash
    }
}
import Foundation
import CryptoKit
import UIKit
import Accelerate
import Accelerate.vImage

/// Errors that can occur while computing perceptual hashes.
public enum ImageHashingError: Error {
    /// The provided data could not be decoded into a valid `CGImage`.
    case invalidImageData
}

/// A utility for computing cryptographic and perceptual image hashes.
public struct ImageHashing {
    private init() {}

    // MARK: - Cryptographic Hash (SHA-256)

    /// Computes a SHA-256 hash and returns it as a lowercase hexadecimal string.
    /// - Parameter data: Raw image data (encrypted or unencrypted).
    /// - Returns: 64-character lowercase hex digest.
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Perceptual Hash (pHash)

    /// Computes a 64-bit perceptual hash (pHash) using a 32×32 DCT kernel.
    /// - Parameter image: A `UIImage` instance. (If you only have `Data`,
    ///   initialise a `UIImage` first so iOS can decrypt HEICs, etc.)
    /// - Returns: 64-bit integer where each bit encodes a coefficient's sign.
    /// - Throws: `ImageHashingError.invalidImageData` if the image can't be decoded.
    public static func perceptualHash(of image: UIImage) throws -> UInt64 {
        guard let cgImage = image.cgImage ?? UIImage(data: image.pngData() ?? .init())?.cgImage else {
            throw ImageHashingError.invalidImageData
        }

        // 1. Resize to 32×32 grayscale (8-bit) using vImage for speed.
        let dimension = 32
        var format = vImage_CGImageFormat(bitsPerComponent: 8,
                                         bitsPerPixel: 8,
                                         colorSpace: nil,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         version: 0,
                                         decode: nil,
                                         renderingIntent: .defaultIntent)

        var sourceBuffer = try vImage_Buffer(cgImage: cgImage)
        defer { sourceBuffer.free() }

        // Destination buffer - 32×32 single-channel.
        let destRowBytes = dimension
        guard let destData = malloc(dimension * dimension) else {
            throw ImageHashingError.invalidImageData
        }
        var destBuffer = vImage_Buffer(data: destData,
                                      height: vImagePixelCount(dimension),
                                      width: vImagePixelCount(dimension),
                                      rowBytes: destRowBytes)
        defer { destBuffer.free() }

        // Use vImageScale_Planar8 instead of vImageScale_ARGB8888ToPlanar8
        // First convert to grayscale if needed
        var grayBuffer = try vImage_Buffer(width: Int(sourceBuffer.width),
                                           height: Int(sourceBuffer.height),
                                           bitsPerPixel: 8)
        defer { grayBuffer.free() }
        
        // Convert ARGB to grayscale
        vImageConvert_ARGB8888toPlanar8(&sourceBuffer, &grayBuffer, &grayBuffer, &grayBuffer, &grayBuffer, vImage_Flags(kvImageNoFlags))
        
        // Scale the grayscale image
        vImageScale_Planar8(&grayBuffer, &destBuffer, nil, vImage_Flags(kvImageHighQualityResampling))

        // 2. Convert UInt8 → Float and center around zero.
        var floatPixels = [Float](repeating: 0, count: dimension * dimension)
        vDSP_vfltu8(destBuffer.data!.assumingMemoryBound(to: UInt8.self), 1,
                    &floatPixels, 1, vDSP_Length(floatPixels.count))
        var mean: Float = 0
        vDSP_meanv(floatPixels, 1, &mean, vDSP_Length(floatPixels.count))
        var minusMean = -mean
        vDSP_vsadd(floatPixels, 1, &minusMean, &floatPixels, 1, vDSP_Length(floatPixels.count))

        // 3. Perform 2-D DCT.
        guard let dctSetup = vDSP_DCT_CreateSetup(nil, vDSP_Length(dimension), .II) else {
            throw ImageHashingError.invalidImageData
        }
        defer { vDSP_DFT_DestroySetup(dctSetup) }

        var dctTemp = [Float](repeating: 0, count: floatPixels.count)
        vDSP_DCT_Execute(dctSetup, &floatPixels, &dctTemp)

        // 4. Extract top-left 8×8 DCT coefficients, ignoring DC component.
        var hash: UInt64 = 0
        var values: [Float] = []
        for row in 0..<8 {
            for col in 0..<8 {
                if row == 0 && col == 0 { continue } // Skip DC component.
                let idx = row * dimension + col
                values.append(dctTemp[idx])
            }
        }
        
        // Compute median using vDSP
        let sortedValues = values.sorted()
        let median: Float
        if sortedValues.count % 2 == 0 {
            median = (sortedValues[sortedValues.count / 2 - 1] + sortedValues[sortedValues.count / 2]) / 2
        } else {
            median = sortedValues[sortedValues.count / 2]
        }

        // Set bit if coefficient > median.
        for (i, coeff) in values.enumerated() {
            if coeff > median {
                hash |= (1 << i)
            }
        }

        return hash
    }

    /// Hexadecimal representation of a perceptual hash.
    @inlinable
    public static func perceptualHashHex(of image: UIImage) throws -> String {
        let pHash = try perceptualHash(of: image)
        return String(format: "%016llx", pHash)
    }

    // MARK: - Combined Helpers

    /// Computes both SHA-256 (hex) and perceptual hash (hex) for a `UIImage`.
    /// - Returns: Tuple `(sha256, pHashHex)`.
    public static func hashes(for image: UIImage) throws -> (String, String) {
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else {
            throw ImageHashingError.invalidImageData
        }
        let sha = sha256Hex(of: jpeg)
        let pHex = try perceptualHashHex(of: image)
        return (sha, pHex)
    }

    /// Async convenience wrapper for Swift Concurrency.
    public static func hashes(for image: UIImage) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try hashes(for: image)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Similarity Helpers

    /// Returns the Hamming distance (0-64) between two perceptual hashes.
    @inlinable
    public static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Convenience for similarity comparison using a threshold (default ≤ 5).
    @inlinable
    public static func areSimilar(_ lhs: UInt64, _ rhs: UInt64, threshold: Int = 5) -> Bool {
        hammingDistance(lhs, rhs) <= threshold
    }
}

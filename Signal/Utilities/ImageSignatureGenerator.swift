import UIKit
import CoreImage
import SignalServiceKit

public final class ImageSignatureGenerator {
    public static let shared = ImageSignatureGenerator()
    private init() { }

    // 32-byte, hex-encoded SHA-256
    public func generateSignature(for img: UIImage) -> String? {
        guard let data = img.jpegData(compressionQuality: 0.8) else { return nil }
        return Cryptography.sha256(data).hexadecimalString
    }

    // 64-bit average hash → 16-char hex
    public func generatePerceptualHash(for img: UIImage) -> String? {
        guard let cg = img.cgImage else { return nil }

        // 1. Down-sample to 8×8 gray
        let ci = CIImage(cgImage: cg)
        let resized = ci.transformed(by: .init(scaleX: 8 / ci.extent.width,
                                             y: 8 / ci.extent.height))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let tiny = ctx.createCGImage(resized,
                                         from: CGRect(x: 0, y: 0, width: 8, height: 8)),
              let data = tiny.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }

        // 2. Grab the first byte of every BGRA pixel (they're all identical after gray),
        //    compute average brightness.
        var lum = [UInt8](repeating: 0, count: 64)
        var sum: UInt64 = 0
        for i in 0..<64 {
            lum[i] = bytes[i * 4]          // B component
            sum += UInt64(lum[i])
        }
        let avg = UInt8(sum / 64)

        // 3. Build bitset – bit i == 1 if pixel_i > average.
        var bits: UInt64 = 0
        for i in 0..<64 where lum[i] > avg {
            bits |= 1 << i                // << not =
        }

        return String(format: "%016llx", bits)   // 16-char hex
    }
} 
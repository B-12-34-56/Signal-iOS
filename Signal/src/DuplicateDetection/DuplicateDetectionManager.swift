import Foundation
import UIKit
import CryptoKit
import Vision
import os.log

class DuplicateDetectionManager {
    static let shared = DuplicateDetectionManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "DuplicateDetectionManager")

    // Use Revision 1 consistently (iOS 13+)
    private let featurePrintRevision = VNGenerateImageFeaturePrintRequestRevision1

    /// Generates a Vision‑SHA256 signature, or falls back to an 8×8 average hash.
    func digitalSignature(for image: UIImage) async throws -> String {
        if let pHash = try? await computePerceptualHash(for: image) {
            return pHash
        }
        logger.warning("Vision FeaturePrint failed, falling back to 8×8 average hash.")
        return HashUtils.averageHash8x8(image)
    }

    /// Handy helper if you want *both* values at once:
    func combinedSignatures(for image: UIImage) async throws -> (vision: String, aHash: String) {
        let vision = try await digitalSignature(for: image)
        let aHash  = HashUtils.averageHash8x8(image)
        return (vision, aHash)
    }

    // MARK: - Vision pHash

    private func computePerceptualHash(for image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "DuplicateDetection", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to get CGImage"])
        }

        return try await withCheckedThrowingContinuation { cont in
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = featurePrintRevision

            do {
               try VNImageRequestHandler(cgImage: cgImage, options: [:])
                    .perform([request])

               if let feature = request.results?.first {
                   let data = feature.data
                   let hash = SHA256.hash(data: data)
                   let hex  = hash.compactMap { String(format: "%02x", $0) }.joined()
                   cont.resume(returning: hex)
               } else {
                   let err = NSError(domain: "DuplicateDetection", code: 2,
                                     userInfo: [NSLocalizedDescriptionKey: "No feature print generated"])
                   logger.error("Vision failed: \(err.localizedDescription)")
                   cont.resume(throwing: err)
               }
            } catch {
               logger.error("Vision request error: \(error)")
               cont.resume(throwing: error)
            }
        }
    }
}

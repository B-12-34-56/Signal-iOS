import UIKit
import Vision

public actor DuplicateDetectionManager {
    public static let shared = DuplicateDetectionManager()

    /// Uses Vision’s feature‑print for a more collision‑resistant fingerprint.
    public func digitalSignature(for image: UIImage) async throws -> String {
        guard let cg = image.cgImage else {
            throw NSError(domain: "DupDetect", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No CGImage"])
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        guard let fp = request.results?.first as? VNFeaturePrintObservation else {
            throw NSError(domain: "DupDetect", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed FeaturePrint"])
        }
        // Serialize via NSKeyedArchiver
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: fp,
            requiringSecureCoding: true
        )
        return data.base64EncodedString()
    }
}

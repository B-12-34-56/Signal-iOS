import Foundation
import UIKit
import AWSS3

class AWSService {
    static let shared = AWSService()
    private var uploadedImageCache: [String: String] = [:]

    func uploadImage(_ image: UIImage, progressHandler: ((Double) -> Void)? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let imageData: Data
        let fileExt: String
        if let pngData = image.pngData() {
            imageData = pngData
            fileExt = "png"
        } else if let jpegData = image.jpegData(compressionQuality: 1.0) {
            imageData = jpegData
            fileExt = "jpg"
        } else {
            completion(.failure(NSError(domain: "AWSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])))
            return
        }

        let hash = ContentDetector.computeImageHash(data: imageData)
        let ext = ContentDetector.determineImageExtension(for: image, data: imageData)
        let objectKey = "images/\(hash).\(ext)"

        if let cachedURL = uploadedImageCache[hash] {
            completion(.success(cachedURL))
            return
        }

        GlobalSignatureService.shared.getImageSignature(hash: hash) { result in
            switch result {
            case .success(let item):
                if let existingURL = item?["S3Key"]?.s {
                    self.uploadedImageCache[hash] = existingURL
                    completion(.success(existingURL))
                } else {
                    self.startS3Upload(data: imageData, key: objectKey, hash: hash, completion: completion)
                }
            case .failure:
                self.startS3Upload(data: imageData, key: objectKey, hash: hash, completion: completion)
            }
        }
    }

    private func startS3Upload(data: Data, key: String, hash: String, completion: @escaping (Result<String, Error>) -> Void) {
        // Implement S3 upload logic here, then call GlobalSignatureService.shared.saveImageSignature
        // For brevity, this is a stub:
        let s3URL = "https://your-s3-bucket.amazonaws.com/\(key)"
        GlobalSignatureService.shared.saveImageSignature(hash: hash, s3Key: s3URL) { result in
            switch result {
            case .success:
                self.uploadedImageCache[hash] = s3URL
                completion(.success(s3URL))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func generateS3Key(for data: Data) -> String {
        let hash = ContentDetector.computeImageHash(data: data)
        let ext = "jpg" // Or detect from data if needed
        return "images/\(hash).\(ext)"
    }
} 
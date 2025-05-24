import Foundation
import UIKit
import AWSS3

class AWSService {
    static let shared = AWSService()
    private var uploadedImageCache: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "ImageHashCache") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "ImageHashCache") }
    }

    func uploadImageWithOriginalData(
        _ image: UIImage,
        originalData: Data?,
        fileURL: URL?,
        progressHandler: ((Double) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let hash: String
        let imageData: Data
        let fileExt: String

        if let original = originalData {
            hash = ContentDetector.computeImageHash(data: original)
            imageData = original
            fileExt = ContentDetector.determineImageExtension(from: original)
        } else if let url = fileURL, let fileData = try? Data(contentsOf: url) {
            hash = ContentDetector.computeImageHash(data: fileData)
            imageData = fileData
            fileExt = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        } else {
            guard let normalizedData = normalizeImage(image) else {
                completion(.failure(NSError(domain: "AWSService", code: -1)))
                return
            }
            hash = ContentDetector.computeImageHash(data: normalizedData)
            imageData = normalizedData
            fileExt = "jpg"
        }

        let objectKey = "images/\(hash).\(fileExt)"

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

    private func normalizeImage(_ image: UIImage) -> Data? {
        let maxSize: CGFloat = 2048
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let normalizedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return normalizedImage.jpegData(compressionQuality: 0.95)
    }

    func generateS3Key(for data: Data) -> String {
        let hash = ContentDetector.computeImageHash(data: data)
        let ext = "jpg" // Or detect from data if needed
        return "images/\(hash).\(ext)"
    }
} 
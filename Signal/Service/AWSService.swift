import Foundation
<<<<<<< HEAD
import AWSCore
import AWSS3
import AWSDynamoDB
import CryptoKit
import UIKit
import Logging

// Singleton service for AWS-based duplicate image filtering
final class AWSService {
    static let shared = AWSService()
    private let logger = Logger(label: "org.signal.AWSService")
    private var isConfigured = false
    // In-memory cache for uploaded image hashes (hash -> S3 URL)
    private var uploadedImageCache: [String: String] = [:]

    private init() {}

    // MARK: - AWS Setup
    func configureAWS(region: AWSRegionType, identityPoolId: String) {
        guard !isConfigured else { return }
        let credentialsProvider = AWSCognitoCredentialsProvider(regionType: region, identityPoolId: identityPoolId)
        let configuration = AWSServiceConfiguration(region: region, credentialsProvider: credentialsProvider)
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        isConfigured = true
        logger.info("AWS configured with region: \(region) and identityPoolId: \(identityPoolId)")
    }

    // MARK: - Image Upload with Deduplication
    /// Upload an image to S3, avoiding duplicates. Returns the S3 URL or error.
    func uploadImage(_ image: UIImage,
                    progressHandler: ((Double) -> Void)? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        // 1. Get image data (prefer PNG, fallback to JPEG)
        let imageData: Data
        let fileExt: String
        if let pngData = image.pngData() {
            imageData = pngData
            fileExt = "png"
        } else if let jpegData = image.jpegData(compressionQuality: 1.0) {
            imageData = jpegData
            fileExt = "jpg"
        } else {
            completion(.failure(AWSServiceError.invalidImage))
            return
        }

        // 2. Compute SHA-256 hash using ContentDetector
        let hash = ContentDetector.computeImageHash(data: imageData)
        let ext = ContentDetector.determineImageExtension(for: image, data: imageData)
        let objectKey = "images/\(hash).\(ext)"

        // 3. Local cache check
        if let cachedURL = uploadedImageCache[hash] {
            logger.info("Image with hash \(hash) already uploaded. Reusing URL.")
=======
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
>>>>>>> origin/Ibrahim
            completion(.success(cachedURL))
            return
        }

<<<<<<< HEAD
        // 4. DynamoDB check (async)
        Task {
            if let s3Key = await GlobalSignatureService.shared.getS3Key(for: hash) {
                let url = AWSConfig.s3BaseURL + s3Key
                self.uploadedImageCache[hash] = url
                logger.info("Duplicate image found in DynamoDB. Reusing URL: \(url)")
                completion(.success(url))
                return
            }
            // 5. Not found, upload to S3
            self.startS3Upload(data: imageData, key: objectKey, hash: hash, progressHandler: progressHandler, completion: completion)
        }
    }

    private func startS3Upload(data: Data, key: String, hash: String,
                               progressHandler: ((Double) -> Void)? = nil,
                               completion: @escaping (Result<String, Error>) -> Void) {
        let uploadExpression = AWSS3TransferUtilityUploadExpression()
        if let progressHandler = progressHandler {
            uploadExpression.progressBlock = { _, progress in
                let fraction = Double(progress.fractionCompleted)
                progressHandler(fraction)
            }
        }
        let transferUtility = AWSS3TransferUtility.default()
        transferUtility.uploadData(data,
                                   bucket: AWSConfig.s3BucketName,
                                   key: key,
                                   contentType: Self.guessContentType(forExtension: (key as NSString).pathExtension),
                                   expression: uploadExpression) { [weak self] task, error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("❌ S3 upload failed for key \(key): \(error)")
                completion(.failure(error))
            } else {
                let urlString = AWSConfig.s3BaseURL + key
                self.uploadedImageCache[hash] = urlString
                // Store hash and S3 key in DynamoDB for future dedup
                Task {
                    _ = await GlobalSignatureService.shared.store(hash: hash, s3Key: key)
                    self.logger.info("✅ Uploaded image with hash \(hash). URL: \(urlString)")
                    completion(.success(urlString))
                }
=======
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
>>>>>>> origin/Ibrahim
            }
        }
    }

<<<<<<< HEAD
    // MARK: - Hashing and Helpers
    static func computeImageHash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func guessContentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}

enum AWSServiceError: Error {
    case invalidImage
    case duplicateImage
}

// MARK: - UIImage Utilities for pHash
private extension UIImage {
    func resized(to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    func grayscale() -> UIImage? {
        let context = CIContext()
        guard let ciImage = CIImage(image: self),
              let filter = CIFilter(name: "CIPhotoEffectMono") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    func dct2D() -> [[Double]]? {
        // Simple DCT implementation for 32x32 grayscale
        guard let cgImage = self.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width == 32, height == 32 else { return nil }
        guard let data = cgImage.dataProvider?.data as Data? else { return nil }
        let pixels = [UInt8](data)
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 32), count: 32)
        for y in 0..<32 {
            for x in 0..<32 {
                matrix[y][x] = Double(pixels[y * 32 + x])
            }
        }
        // 2D DCT (naive, for demonstration)
        var dct = [[Double]](repeating: [Double](repeating: 0, count: 32), count: 32)
        for u in 0..<32 {
            for v in 0..<32 {
                var sum = 0.0
                for x in 0..<32 {
                    for y in 0..<32 {
                        sum += matrix[y][x] *
                            cos((Double.pi/32.0) * Double(u) * (Double(x) + 0.5)) *
                            cos((Double.pi/32.0) * Double(v) * (Double(y) + 0.5))
                    }
                }
                let cu = u == 0 ? 1.0 / sqrt(2.0) : 1.0
                let cv = v == 0 ? 1.0 / sqrt(2.0) : 1.0
                dct[u][v] = 0.25 * cu * cv * sum
            }
        }
        return dct
    }
    func phashString() -> String? {
        // Take top-left 8x8 DCT coefficients, except DC
        guard let dct = self.dct2D() else { return nil }
        var hash = ""
        var values: [Double] = []
        for y in 0..<8 {
            for x in 0..<8 {
                if x != 0 || y != 0 {
                    values.append(dct[y][x])
                }
            }
        }
        let median = values.sorted()[values.count/2]
        for v in values {
            hash += v > median ? "1" : "0"
        }
        return hash
=======
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
>>>>>>> origin/Ibrahim
    }
} 
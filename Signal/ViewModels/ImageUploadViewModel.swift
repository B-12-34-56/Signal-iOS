import Foundation
import UIKit
import AWSS3
import AWSDynamoDB
import SignalServiceKit

public enum ImageFilter {
    case none
    case mono
    case vibrant
    case sepia
}

public class ImageUploadViewModel {
    private let duplicateService = AWSDuplicateService.shared
    private let dynamoDBManager = DynamoDBServiceManager.shared
    private let signatureGenerator = ImageSignatureGenerator.shared
    private let bucket = Bundle.main.object(forInfoDictionaryKey: "S3_BUCKET_NAME") as? String ?? ""
    
    public init() {}
    
    // MARK: - Image Upload with Duplicate Detection
    
    public func uploadImage(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        // Use the new duplicate service for duplicate detection
        duplicateService.checkForDuplicate(signature: computeImageHash(image), perceptualHash: signatureGenerator.generatePerceptualHash(for: image) ?? "") { [weak self] result in
            switch result {
            case .success(let isDuplicate):
                if isDuplicate {
                    completion(.failure(NSError(domain: "ImageUpload", code: -2, userInfo: [NSLocalizedDescriptionKey: "Duplicate image detected"])))
                    return
                }
                
                // If not a duplicate, proceed with S3 upload
                let key = "images/\(UUID().uuidString).jpg"
                
                // Convert image to data with compression
                guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                    completion(.failure(NSError(domain: "ImageUpload", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])))
                    return
                }
                
                // Upload to S3 directly using AWS SDK
                let expr = AWSS3TransferUtilityUploadExpression()
                expr.progressBlock = { _, progress in
                    NotificationCenter.default.post(name: .awsUploadProgress,
                                                 object: key,
                                                 userInfo: ["fraction": progress.fractionCompleted])
                }
                
                AWSS3TransferUtility.default().uploadData(
                    imageData,
                    bucket: self?.bucket ?? "",
                    key: key,
                    contentType: "application/octet-stream",
                    expression: expr) { task, error in
                        DispatchQueue.main.async {
                            if let error = error {
                                completion(.failure(error))
                                return
                            }
                            
                            // After successful S3 upload, store signatures in DynamoDB
                            self?.dynamoDBManager.storeSignature(
                                signature: self?.computeImageHash(image) ?? "",
                                perceptualHash: self?.signatureGenerator.generatePerceptualHash(for: image) ?? "",
                                imageKey: key) { result in
                                    switch result {
                                    case .success:
                                        completion(.success(key))
                                    case .failure(let error):
                                        // If DynamoDB storage fails, delete the S3 object
                                        self?.deleteImage(key: key) { _ in }
                                        completion(.failure(error))
                                    }
                            }
                        }
                }
                
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    private func deleteImage(key: String, completion: @escaping (Error?) -> Void) {
        let req = AWSS3DeleteObjectRequest()!
        req.bucket = bucket
        req.key = key
        AWSS3.default().deleteObject(req) { _, err in 
            DispatchQueue.main.async { 
                completion(err) 
            } 
        }
    }
    
    // MARK: - Image Filtering
    
    public func applyFilter(_ image: UIImage, filter: ImageFilter) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext()
        
        var filteredImage: CIImage?
        
        switch filter {
        case .none:
            return image
            
        case .mono:
            let filter = CIFilter(name: "CIPhotoEffectMono")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filteredImage = filter?.outputImage
            
        case .vibrant:
            let filter = CIFilter(name: "CIVibrance")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(1.0, forKey: kCIInputAmountKey)
            filteredImage = filter?.outputImage
            
        case .sepia:
            let filter = CIFilter(name: "CISepiaTone")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(0.8, forKey: kCIInputIntensityKey)
            filteredImage = filter?.outputImage
        }
        
        guard let filteredImage = filteredImage,
              let outputCGImage = context.createCGImage(filteredImage, from: filteredImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: outputCGImage)
    }
    
    // MARK: - Image Hashing
    
    public func computeImageHash(_ image: UIImage) -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            return UUID().uuidString
        }
        
        // Use SHA-256 for image hashing
        let hash = Cryptography.sha256(imageData)
        return hash.hexadecimalString
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let awsUploadProgress = Notification.Name("awsUploadProgress")
} 
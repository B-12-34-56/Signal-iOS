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
    private let awsManager = AWSServiceManager.shared
    private let dynamoDBManager = DynamoDBServiceManager.shared
    private let signatureGenerator = ImageSignatureGenerator.shared
    
    public init() {}
    
    // MARK: - Image Upload with Duplicate Detection
    
    public func uploadImage(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        // Generate signatures for duplicate detection
        guard let signature = signatureGenerator.generateSignature(for: image),
              let perceptualHash = signatureGenerator.generatePerceptualHash(for: image) else {
            completion(.failure(NSError(domain: "ImageUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate image signatures"])))
            return
        }
        
        // First check DynamoDB for duplicates
        dynamoDBManager.checkForDuplicate(signature: signature, perceptualHash: perceptualHash) { [weak self] result in
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
                
                // Upload to S3
                self?.awsManager.uploadImageData(imageData, key: key) { result in
                    switch result {
                    case .success:
                        // After successful S3 upload, store signatures in DynamoDB
                        self?.dynamoDBManager.storeSignature(signature: signature, perceptualHash: perceptualHash, imageKey: key) { result in
                            switch result {
                            case .success:
                                completion(.success(key))
                            case .failure(let error):
                                // If DynamoDB storage fails, we should delete the S3 object
                                self?.awsManager.deleteImage(key: key) { _ in }
                                completion(.failure(error))
                            }
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
                
            case .failure(let error):
                completion(.failure(error))
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
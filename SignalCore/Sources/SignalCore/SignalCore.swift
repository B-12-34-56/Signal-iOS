import Foundation
import UIKit
import AWSCore
import AWSS3
import AWSDynamoDB
import CommonCrypto

public struct SignalCore {
    public static let shared = SignalCore()
    
    private init() {}
    
    public func initialize() {
        // Initialize AWS configuration
        if let configuration = AWSConfig.shared.configuration {
            AWSServiceManager.default().defaultServiceConfiguration = configuration
        }
    }
    
    // MARK: - Image Processing
    
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
    
    public func computeImageHash(_ image: UIImage) -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            return UUID().uuidString
        }
        
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = imageData.withUnsafeBytes { buffer in
            CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Image Filter

public enum ImageFilter: Int {
    case none = 0
    case mono = 1
    case vibrant = 2
    case sepia = 3
}

// MARK: - AWS Service

public class AWSService {
    public static let shared = AWSService()
    
    private init() {}
    
    public func uploadImage(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(.failure(NSError(domain: "AWSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])))
            return
        }
        
        let key = "\(UUID().uuidString).jpg"
        let request = AWSS3PutObjectRequest()
        request?.bucket = AWSConfig.shared.bucketName
        request?.key = key
        request?.body = imageData
        request?.contentType = "image/jpeg"
        
        AWSS3.default().putObject(request!) { (response, error) in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            let imageURL = "\(AWSConfig.shared.baseURL)/\(key)"
            completion(.success(imageURL))
        }
    }
    
    public func checkImageSignature(hash: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let dynamoDB = AWSDynamoDB.default()
        let queryInput = AWSDynamoDBQueryInput()
        queryInput?.tableName = AWSConfig.shared.signaturesTableName
        queryInput?.keyConditionExpression = "hash = :hash"
        
        let hashAttr = AWSDynamoDBAttributeValue()!
        hashAttr.s = hash
        queryInput?.expressionAttributeValues = [":hash": hashAttr]
        
        dynamoDB.query(queryInput!) { (response, error) in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            let isDuplicate = (response?.items?.count ?? 0) > 0
            completion(.success(isDuplicate))
        }
    }
    
    public func storeImageSignature(hash: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let dynamoDB = AWSDynamoDB.default()
        let item = AWSDynamoDBPutItemInput()
        item?.tableName = AWSConfig.shared.signaturesTableName
        
        let hashAttr = AWSDynamoDBAttributeValue()!
        hashAttr.s = hash
        
        let timestampAttr = AWSDynamoDBAttributeValue()!
        timestampAttr.n = String(Date().timeIntervalSince1970)
        
        item?.item = [
            "hash": hashAttr,
            "timestamp": timestampAttr
        ]
        
        dynamoDB.putItem(item!) { (response, error) in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            completion(.success(()))
        }
    }
    
    public func getImageTag(imageURL: String, completion: @escaping (Result<String, Error>) -> Void) {
        // Implement image tagging logic here
        // For now, return a placeholder tag
        completion(.success("nature"))
    }
} 
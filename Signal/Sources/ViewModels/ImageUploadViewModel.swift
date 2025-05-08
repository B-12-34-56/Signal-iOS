import Foundation
import UIKit
import AWSS3
import AWSDynamoDB
import SignalServiceKit

public enum ImageFilter: Int {
    case none = 0
    case mono = 1
    case vibrant = 2
    case sepia = 3
}

public class ImageUploadViewModel {
    private let awsManager = AWSServiceManager.shared
    
    public init() {}
    
    public func applyFilter(_ image: UIImage, filter: ImageFilter) -> UIImage? {
        let ciImage = CIImage(image: image)
        guard let ciImage = ciImage else { return nil }
        
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
              let cgImage = context.createCGImage(filteredImage, from: filteredImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    public func uploadImage(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(.failure(NSError(domain: "ImageUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])))
            return
        }
        
        let key = "images/\(UUID().uuidString).jpg"
        
        awsManager.uploadImage(imageData, key: key) { result in
            switch result {
            case .success(let url):
                completion(.success(url))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
} 
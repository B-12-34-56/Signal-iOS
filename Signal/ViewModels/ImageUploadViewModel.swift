import Foundation
import UIKit
import AWSS3
import SignalServiceKit

public enum ImageFilter {
    case none
    case mono
    case vibrant
    case sepia
}

public class ImageUploadViewModel: NSObject {
    private let contentFilterService = ContentFilterService.shared
    
    public init() {}
    
    // MARK: - Image Upload
    
    func uploadImage(_ image: UIImage, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            let error = NSError(domain: "ImageUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to JPEG"])
            handleError(error)
            completion(.failure(error))
            return
        }
        
        // Show progress notification
        NotificationCenter.default.post(
            name: .imageUploadProgress,
            object: nil,
            userInfo: ["progress": 0.0]
        )
        
        // Process and upload image
        contentFilterService.scanAndUpload(imageData: imageData, fileName: "image.jpg") { [weak self] result in
            switch result {
            case .allowed(let tags, let s3URL):
                // Update progress
                NotificationCenter.default.post(
                    name: .imageUploadProgress,
                    object: nil,
                    userInfo: ["progress": 1.0]
                )
                
                // Log allowed tags
                Logger.info("Image allowed with tags: \(tags)")
                
                // Return the S3 URL
                completion(.success(s3URL))
                
            case .blocked(let reason, let tags):
                // Show blocked notification
                NotificationCenter.default.post(
                    name: .imageUploadBlocked,
                    object: nil,
                    userInfo: [
                        "reason": reason,
                        "tags": tags
                    ]
                )
                
                // Log blocked reason and tags
                Logger.warn("Image blocked: \(reason), tags: \(tags)")
                
                // Show alert for duplicate images
                if reason == "Duplicate image detected" {
                    DispatchQueue.main.async {
                        let alert = UIAlertController(
                            title: "Duplicate Image",
                            message: "This image has been sent too many times.",
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        
                        // Present alert on topmost view controller
                        if let topVC = UIApplication.shared.topMostViewController() {
                            topVC.present(alert, animated: true)
                        }
                    }
                }
                
                // Return error
                let error = NSError(domain: "ImageUpload", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: reason,
                    "tags": tags
                ])
                completion(.failure(error))
                
            case .error(let error):
                self?.handleError(error)
                completion(.failure(error ?? NSError(domain: "ImageUpload", code: -3)))
            }
        }
    }
    
    private func handleError(_ error: Error?) {
        // Show error notification
        NotificationCenter.default.post(
            name: .imageUploadError,
            object: nil,
            userInfo: ["error": error as Any]
        )
        
        // Log error
        if let error = error {
            Logger.error("Image upload error: \(error)")
        } else {
            Logger.error("Unknown image upload error")
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
}

// MARK: - Notification Names

extension Notification.Name {
    static let imageUploadProgress = Notification.Name("imageUploadProgress")
    static let imageUploadBlocked = Notification.Name("imageUploadBlocked")
    static let imageUploadError = Notification.Name("imageUploadError")
    static let imageUploadDuplicate = Notification.Name("imageUploadDuplicate")
} 
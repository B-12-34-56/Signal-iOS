//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import SignalServiceKit

enum ImageFilter {
    case none
    case mono
    case vibrant
    case sepia
}

class ImageUploadViewModel {
    // MARK: - Image Filtering
    
    func applyFilter(_ image: UIImage, filter: ImageFilter) -> UIImage? {
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
    
    func computeImageHash(_ image: UIImage) -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            return UUID().uuidString
        }
        
        // Use SHA-256 for image hashing
        let hash = Cryptography.sha256(imageData)
        return hash.hexadecimalString
    }
} 
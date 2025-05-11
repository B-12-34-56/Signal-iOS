import Foundation

class ContentDetector {
    private let awsManager = AWSManager.shared
    
    func processImage(at url: URL) async throws -> Bool {
        // Read the image data
        let imageData = try Data(contentsOf: url)
        
        // Check for duplicates
        let isDuplicate = try await awsManager.checkForDuplicate(imageData: imageData)
        
        if isDuplicate {
            // If it's a duplicate, return false to indicate it was blocked
            return false
        }
        
        // If not a duplicate, store the signature
        try await awsManager.storeImageSignature(imageData: imageData)
        
        // Return true to indicate the image was processed successfully
        return true
    }
} 
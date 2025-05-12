import Foundation
import Logging

public final class DuplicateDetector {
    public static let shared = DuplicateDetector()
    
    private let logger = Logger(label: "org.signal.DuplicateDetector")
    private let imageHasher = ImageHasher.shared
    private let globalSignatureService = GlobalSignatureService.shared
    
    private init() {}
    
    /// Checks if an image is a duplicate by computing its hash and checking against the global signature service
    /// - Parameter imageData: The raw image data to check
    /// - Returns: True if the image is a duplicate, false otherwise
    /// - Throws: GlobalSignatureServiceError if the check fails
    public func isDuplicate(_ imageData: Data) async throws -> Bool {
        logger.debug("Checking for duplicate image")
        
        // Compute hash
        let hash = imageHasher.hash(imageData)
        
        // Check against global service
        return try await globalSignatureService.checkHashExists(hash)
    }
    
    /// Stores an image's hash in the global signature service
    /// - Parameter imageData: The raw image data to store
    /// - Throws: GlobalSignatureServiceError if storage fails
    public func storeHash(_ imageData: Data) async throws {
        logger.debug("Storing image hash")
        
        // Compute hash
        let hash = imageHasher.hash(imageData)
        
        // Store in global service
        try await globalSignatureService.storeHash(hash)
    }
    
    /// Checks multiple images for duplicates in parallel
    /// - Parameter images: Array of image data to check
    /// - Returns: Array of booleans indicating which images are duplicates
    /// - Throws: GlobalSignatureServiceError if any check fails
    public func checkDuplicates(_ images: [Data]) async throws -> [Bool] {
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            for image in images {
                group.addTask {
                    try await self.isDuplicate(image)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
} 
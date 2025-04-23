#!/usr/bin/env swift

import Foundation
// No UIKit dependency - purely Foundation-based implementation

// MARK: - Script Configuration

// Get command line arguments for image path and test iterations
let arguments = CommandLine.arguments
var imagePath: String?
var iterations = 3 // Default iterations

if arguments.count > 1 {
    imagePath = arguments[1]
}

if arguments.count > 2, let iterArg = Int(arguments[2]) {
    iterations = iterArg
}

// MARK: - Logging

class Logger {
    static func debug(_ message: String) {
        print("[DEBUG] \(message)")
    }
    
    static func info(_ message: String) {
        print("[INFO] \(message)")
    }
    
    static func error(_ message: String) {
        print("[ERROR] \(message)")
    }
}

// MARK: - Simplified Content Hash Generation

// Content hash generator that works with raw data without UIKit
struct ContentHashGenerator {
    // Generate a hash from raw data
    static func generateHash(from data: Data) -> String {
        // Use Swift's built-in hashValue - in a production environment,
        // you might want a more robust hashing algorithm like SHA-256
        let hashValue = data.hashValue
        return String(hashValue)
    }
    
    // More robust hash using CryptoKit if available (iOS 13+/macOS 10.15+)
    // This is a simplified example - not actually calling CryptoKit
    static func generateSecureHash(from data: Data) -> String {
        // For a simplified example, we'll still use hashValue
        // In a real implementation, you would use:
        // SHA256.hash(data: data).description
        let hashValue = data.reduce(0) { ($0 &+ Int($1)) &* 17 }
        return String(hashValue)
    }
    
    // Check if data appears to be an image based on magic numbers
    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        
        // Check for common image format signatures
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        
        let bytes = [UInt8](data.prefix(4))
        
        // Check for JPEG signature
        if bytes.count >= 3 && bytes[0] == jpeg[0] && bytes[1] == jpeg[1] && bytes[2] == jpeg[2] {
            return true
        }
        
        // Check for PNG signature
        if bytes.count >= 4 && bytes[0] == png[0] && bytes[1] == png[1] && bytes[2] == png[2] && bytes[3] == png[3] {
            return true
        }
        
        // Add more image format checks if needed
        
        return false
    }
}

// MARK: - Mock Signal Classes for Testing

// Simple file format detection
enum FileType: String {
    case jpeg = "public.jpeg"
    case png = "public.png"
    case unknown = "public.data"
    
    static func detect(fromData data: Data) -> FileType {
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 {
            return .jpeg
        }
        if data.count >= 8 && data[0] == 0x89 && data[1] == 0x50 && 
           data[2] == 0x4E && data[3] == 0x47 {
            return .png
        }
        return .unknown
    }
}

// Mock DataSource to simulate Signal's DataSource class without UIKit dependency
class DataSource {
    let data: Data
    var sourceFilename: String?
    var dataUrl: URL?
    
    var dataLength: UInt {
        return UInt(data.count)
    }
    
    var isValidImage: Bool {
        return ContentHashGenerator.looksLikeImage(data)
    }
    
    var fileType: FileType {
        return FileType.detect(fromData: data)
    }
    
    init(data: Data, filename: String? = nil) {
        self.data = data
        self.sourceFilename = filename
    }
}

enum SignalAttachmentError: Error {
    case missingData
    case fileSizeTooLarge
    case invalidData
    case couldNotParseImage
    case unsupportedFileType
}

// Mock SignalAttachment class to simulate Signal's attachment handling without UIKit
class SignalAttachment {
    let dataSource: DataSource
    let dataUTI: String
    
    private var error: Error?
    
    static let kMaxFileSizeImage: UInt = 6 * 1024 * 1024 // 6MB
    static let maxAttachmentsAllowed: Int = 32
    
    // Content hash for duplicate detection
    private let contentHash: String
    
    private init(dataSource: DataSource, dataUTI: String) {
        self.dataSource = dataSource
        self.dataUTI = dataUTI
        
        // Calculate a hash of the data to detect duplicates
        self.contentHash = ContentHashGenerator.generateHash(from: dataSource.data)
    }
    
    // Public accessor for content hash to compare attachments
    public func getContentHash() -> String {
        return contentHash
    }
    
    public var hasError: Bool {
        return error != nil
    }
    
    public var errorDescription: String? {
        return (error as? SignalAttachmentError)?.localizedDescription
    }
    
    public var data: Data {
        return dataSource.data
    }
    
    // Factory method similar to Signal's implementation to create attachments
    static func attachment(dataSource: DataSource, dataUTI: String) -> SignalAttachment {
        let attachment = SignalAttachment(dataSource: dataSource, dataUTI: dataUTI)
        
        // Validate the attachment
        if dataSource.dataLength == 0 {
            attachment.error = SignalAttachmentError.missingData
        }
        
        if dataSource.dataLength > kMaxFileSizeImage {
            attachment.error = SignalAttachmentError.fileSizeTooLarge
        }
        
        if !dataSource.isValidImage {
            attachment.error = SignalAttachmentError.couldNotParseImage
        }
        
        return attachment
    }
    
    // Factory method that auto-detects the file type
    static func imageAttachment(dataSource: DataSource) -> SignalAttachment {
        let fileType = dataSource.fileType
        return attachment(dataSource: dataSource, dataUTI: fileType.rawValue)
    }
}

// MARK: - Duplicate Detection Function

func checkForDuplicateAttachments(_ attachments: [SignalAttachment]) -> [Bool] {
    // Initialize result array: false means not a duplicate
    var isDuplicate = Array(repeating: false, count: attachments.count)
    
    // Dictionary to track content hashes
    var contentHashes = [String: Int]()
    
    // Check each attachment
    for (index, attachment) in attachments.enumerated() {
        let hash = attachment.getContentHash()
        
        // Check if we've seen this hash before
        if let firstIndex = contentHashes[hash] {
            // Mark as duplicate
            isDuplicate[index] = true
            Logger.debug("Attachment #\(index) is a duplicate of #\(firstIndex)")
            Logger.debug("  - Hash: \(hash)")
            Logger.debug("  - File: \(attachment.dataSource.sourceFilename ?? "unknown")")
        } else {
            // First time seeing this hash
            contentHashes[hash] = index
            Logger.debug("Attachment #\(index) is unique, hash: \(hash)")
            Logger.debug("  - File: \(attachment.dataSource.sourceFilename ?? "unknown")")
        }
    }
    
    return isDuplicate
}

// MARK: - Main Script Logic

Logger.info("Starting simplified duplicate image detection test (without UIKit)")

// Ensure we have an image path
guard let imagePath = imagePath else {
    Logger.error("No image path provided")
    Logger.info("Usage: swift simplified_image_detection_test.swift [image_path] [iterations]")
    exit(1)
}

// Try to load the image data
guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
    Logger.error("Failed to load image from path: \(imagePath)")
    exit(1)
}

Logger.info("Loaded image: \(imagePath), size: \(imageData.count) bytes")
Logger.info("Will test \(iterations) duplicate uploads")

// Create multiple attachments using the same image data
var attachments = [SignalAttachment]()

for i in 0..<iterations {
    // In real Signal app, the user might attempt to upload the same image multiple times
    // Here we simulate this by creating multiple attachment objects for the same data
    let dataSource = DataSource(data: imageData, filename: "test_image_\(i).jpg")
    let attachment = SignalAttachment.imageAttachment(dataSource: dataSource)
    
    // Check if the attachment has any errors (too large, invalid format, etc)
    if attachment.hasError {
        Logger.error("Attachment #\(i) has error: \(attachment.errorDescription ?? "unknown error")")
    } else {
        Logger.info("Created attachment #\(i) successfully")
        attachments.append(attachment)
    }
}

// Test duplicate detection
Logger.info("Running duplicate detection...")
let duplicateStatus = checkForDuplicateAttachments(attachments)

// Calculate statistics
let uniqueCount = duplicateStatus.filter({ !$0 }).count
let duplicateCount = duplicateStatus.filter({ $0 }).count

Logger.info("Duplicate detection test results:")
Logger.info("- Total attachments processed: \(attachments.count)")
Logger.info("- Unique attachments detected: \(uniqueCount)")
Logger.info("- Duplicate attachments detected: \(duplicateCount)")

// Summary
if duplicateCount > 0 {
    Logger.info("✅ Attachment system successfully detected duplicates!")
} else if attachments.count > 1 {
    Logger.info("❌ Attachment system failed to detect duplicates")
} else {
    Logger.info("⚠️ Not enough attachments to test duplicate detection")
}

// Try to load a different image if available to test non-duplicate detection
if let differentImagePath = arguments.count > 3 ? arguments[3] : nil,
   let differentImageData = try? Data(contentsOf: URL(fileURLWithPath: differentImagePath)) {
    
    Logger.info("\nTesting with different image: \(differentImagePath)")
    
    // Create a new attachment with different image data
    let dataSource = DataSource(data: differentImageData, filename: "different_image.jpg")
    let newAttachment = SignalAttachment.imageAttachment(dataSource: dataSource)
    
    if !newAttachment.hasError {
        var combinedAttachments = attachments
        combinedAttachments.append(newAttachment)
        
        Logger.info("Checking if system correctly identifies unique images...")
        let combinedStatus = checkForDuplicateAttachments(combinedAttachments)
        
        // The last attachment should not be a duplicate
        if !combinedStatus.last! {
            Logger.info("✅ System correctly identified the different image as unique")
        } else {
            Logger.info("❌ System incorrectly identified the different image as a duplicate")
        }
    }
}

/* 
 * How this duplicate detection works:
 * 
 * 1. We load image data from files without using UIKit
 * 2. For each image, we create a DataSource that holds the raw data
 * 3. The DataSource performs basic file format detection using magic numbers (file signatures)
 * 4. We create SignalAttachment objects from each DataSource
 * 5. During creation, each attachment calculates a content hash based on the raw data
 * 6. The duplicate detection function compares these content hashes
 * 7. If two attachments have the same hash, one is marked as a duplicate
 * 8. This approach allows duplicate detection without requiring UIKit or image rendering
 * 9. In a real implementation, more robust hashing algorithms would be used
 * 10. The system can correctly distinguish between identical and different images
 */
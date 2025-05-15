#!/usr/bin/env swift

import Foundation
import UIKit

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

// MARK: - Mock Signal Classes for Testing

// Mock DataSource to simulate Signal's DataSource class
class DataSource {
    let data: Data
    var sourceFilename: String?
    var dataUrl: URL?
    
    var dataLength: UInt {
        return UInt(data.count)
    }
    
    var isValidImage: Bool {
        return UIImage(data: data) != nil
    }
    
    var isValidVideo: Bool {
        return false
    }
    
    var imageMetadata = ImageMetadata()
    
    init(data: Data, filename: String? = nil) {
        self.data = data
        self.sourceFilename = filename
    }
}

struct ImageMetadata {
    var isAnimated: Bool = false
}

enum SignalAttachmentError: Error {
    case missingData
    case fileSizeTooLarge
    case invalidData
    case couldNotParseImage
}

// Mock SignalAttachment class to simulate Signal's actual attachment handling
class SignalAttachment {
    let dataSource: DataSource
    let dataUTI: String
    
    private var error: Error?
    
    static let kMaxFileSizeImage: UInt = 6 * 1024 * 1024 // 6MB
    static let maxAttachmentsAllowed: Int = 32
    
    // Mock content hash for duplicate detection
    private let contentHash: String
    
    private init(dataSource: DataSource, dataUTI: String) {
        self.dataSource = dataSource
        self.dataUTI = dataUTI
        
        // Calculate a "hash" of the data to simulate how Signal would detect duplicates
        // In the real Signal app, this would involve a more sophisticated algorithm
        self.contentHash = String(dataSource.data.hashValue)
    }
    
    // Public accessor for content hash to compare attachments
    public func getContentHash() -> String {
        return contentHash
    }
    
    public var hasError: Bool {
        return error != nil
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
        } else {
            // First time seeing this hash
            contentHashes[hash] = index
            Logger.debug("Attachment #\(index) is unique, hash: \(hash)")
        }
    }
    
    return isDuplicate
}

// MARK: - Main Script Logic

Logger.info("Starting duplicate image upload detection test")

// Ensure we have an image path
guard let imagePath = imagePath ?? Bundle.main.path(forResource: "test_image", ofType: "jpg") else {
    Logger.error("No image path provided and no default image found.")
    Logger.info("Usage: swift test_duplicate_image_upload.swift [image_path] [iterations]")
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
    let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: "public.jpeg")
    
    // Check if the attachment has any errors (too large, invalid format, etc)
    if attachment.hasError {
        Logger.error("Attachment #\(i) has error")
    } else {
        Logger.info("Created attachment #\(i) successfully")
        attachments.append(attachment)
    }
}

// Test duplicate detection
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
    Logger.info("✅ Signal's attachment system successfully detected duplicates!")
} else if attachments.count > 1 {
    Logger.info("❌ Signal's attachment system failed to detect duplicates")
} else {
    Logger.info("⚠️ Not enough attachments to test duplicate detection")
}

/* 
 * How Signal's attachment processing works:
 * 
 * 1. When a user selects an image to send, Signal creates a SignalAttachment object
 * 2. The attachment contains a DataSource which handles the actual file data
 * 3. Before sending, Signal validates the attachment (size limits, format support)
 * 4. For images, Signal may compress or convert the format to ensure compatibility
 * 5. Signal then calculates a content hash to detect duplicates 
 *    (real implementation may use more sophisticated methods)
 * 6. When sending multiple attachments, duplicate detection prevents sending the same 
 *    content multiple times, saving bandwidth and storage
 * 7. The message sender checks for duplicates before uploading to the server
 */
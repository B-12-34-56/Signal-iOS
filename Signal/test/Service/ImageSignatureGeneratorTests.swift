import XCTest
import UIKit
@testable import Signal

class ImageSignatureGeneratorTests: XCTestCase {
    let signatureGenerator = ImageSignatureGenerator.shared
    
    func testGenerateSignature() {
        // Create a test image
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContext(size)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let testImage = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // Test signature generation
        let signature = signatureGenerator.generateSignature(for: testImage)
        XCTAssertNotNil(signature, "Signature should not be nil")
        XCTAssertEqual(signature?.count, 64, "SHA-256 hash should be 64 characters")
        
        // Test that same image produces same signature
        let signature2 = signatureGenerator.generateSignature(for: testImage)
        XCTAssertEqual(signature, signature2, "Same image should produce same signature")
        
        // Test that different images produce different signatures
        UIGraphicsBeginImageContext(size)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let differentImage = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create different test image")
            return
        }
        UIGraphicsEndImageContext()
        
        let differentSignature = signatureGenerator.generateSignature(for: differentImage)
        XCTAssertNotEqual(signature, differentSignature, "Different images should produce different signatures")
    }
    
    func testGeneratePerceptualHash() {
        // Create a test image
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContext(size)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let testImage = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // Test perceptual hash generation
        let hash = signatureGenerator.generatePerceptualHash(for: testImage)
        XCTAssertNotNil(hash, "Perceptual hash should not be nil")
        XCTAssertEqual(hash?.count, 64, "Perceptual hash should be 64 bits")
        
        // Test that same image produces same hash
        let hash2 = signatureGenerator.generatePerceptualHash(for: testImage)
        XCTAssertEqual(hash, hash2, "Same image should produce same perceptual hash")
        
        // Test that different images produce different hashes
        UIGraphicsBeginImageContext(size)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let differentImage = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create different test image")
            return
        }
        UIGraphicsEndImageContext()
        
        let differentHash = signatureGenerator.generatePerceptualHash(for: differentImage)
        XCTAssertNotEqual(hash, differentHash, "Different images should produce different perceptual hashes")
    }
    
    func testSimilarImages() {
        // Create two similar images
        let size = CGSize(width: 100, height: 100)
        
        // First image
        UIGraphicsBeginImageContext(size)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let image1 = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create first test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // Second image (slightly different)
        UIGraphicsBeginImageContext(size)
        UIColor.red.withAlphaComponent(0.99).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let image2 = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create second test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // Get signatures
        let signature1 = signatureGenerator.generateSignature(for: image1)
        let signature2 = signatureGenerator.generateSignature(for: image2)
        
        // Get perceptual hashes
        let hash1 = signatureGenerator.generatePerceptualHash(for: image1)
        let hash2 = signatureGenerator.generatePerceptualHash(for: image2)
        
        // Test that signatures are different (exact match)
        XCTAssertNotEqual(signature1, signature2, "Similar images should have different exact signatures")
        
        // Test that perceptual hashes are similar
        if let hash1 = hash1, let hash2 = hash2 {
            let hammingDistance = calculateHammingDistance(hash1, hash2)
            XCTAssertLessThan(hammingDistance, 10, "Similar images should have similar perceptual hashes")
        }
    }
    
    private func calculateHammingDistance(_ str1: String, _ str2: String) -> Int {
        guard str1.count == str2.count else { return -1 }
        return zip(str1, str2).filter { $0 != $1 }.count
    }
} 
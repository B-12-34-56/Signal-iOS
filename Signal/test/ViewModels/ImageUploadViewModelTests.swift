import XCTest
import UIKit
@testable import Signal

class ImageUploadViewModelTests: XCTestCase {
    let viewModel = ImageUploadViewModel()
    let signatureGenerator = ImageSignatureGenerator.shared
    
    override func setUp() {
        super.setUp()
        // Any setup code
    }
    
    override func tearDown() {
        // Any cleanup code
        super.tearDown()
    }
    
    func testUploadNewImage() {
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
        
        // Test upload expectation
        let expectation = XCTestExpectation(description: "Image upload completion")
        
        // Attempt to upload
        viewModel.uploadImage(testImage) { result in
            switch result {
            case .success(let key):
                XCTAssertFalse(key.isEmpty, "Uploaded image key should not be empty")
                XCTAssertTrue(key.hasPrefix("images/"), "Image key should start with 'images/'")
                XCTAssertTrue(key.hasSuffix(".jpg"), "Image key should end with '.jpg'")
            case .failure(let error):
                XCTFail("Upload failed with error: \(error.localizedDescription)")
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    func testUploadDuplicateImage() {
        // Create a test image
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContext(size)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let testImage = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // First upload
        let firstUploadExpectation = XCTestExpectation(description: "First image upload")
        viewModel.uploadImage(testImage) { result in
            switch result {
            case .success:
                firstUploadExpectation.fulfill()
            case .failure(let error):
                XCTFail("First upload failed: \(error.localizedDescription)")
            }
        }
        wait(for: [firstUploadExpectation], timeout: 10.0)
        
        // Second upload (should be detected as duplicate)
        let secondUploadExpectation = XCTestExpectation(description: "Duplicate image upload")
        viewModel.uploadImage(testImage) { result in
            switch result {
            case .success:
                XCTFail("Duplicate image should not upload successfully")
            case .failure(let error):
                XCTAssertEqual(error.localizedDescription, "Duplicate image detected")
                secondUploadExpectation.fulfill()
            }
        }
        wait(for: [secondUploadExpectation], timeout: 10.0)
    }
    
    func testUploadSimilarImage() {
        // Create two similar images
        let size = CGSize(width: 100, height: 100)
        
        // First image
        UIGraphicsBeginImageContext(size)
        UIColor.green.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let image1 = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create first test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // Second image (slightly different)
        UIGraphicsBeginImageContext(size)
        UIColor.green.withAlphaComponent(0.99).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let image2 = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create second test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // Upload first image
        let firstUploadExpectation = XCTestExpectation(description: "First image upload")
        viewModel.uploadImage(image1) { result in
            switch result {
            case .success:
                firstUploadExpectation.fulfill()
            case .failure(let error):
                XCTFail("First upload failed: \(error.localizedDescription)")
            }
        }
        wait(for: [firstUploadExpectation], timeout: 10.0)
        
        // Upload similar image
        let secondUploadExpectation = XCTestExpectation(description: "Similar image upload")
        viewModel.uploadImage(image2) { result in
            switch result {
            case .success:
                XCTFail("Similar image should be detected as duplicate")
            case .failure(let error):
                XCTAssertEqual(error.localizedDescription, "Duplicate image detected")
                secondUploadExpectation.fulfill()
            }
        }
        wait(for: [secondUploadExpectation], timeout: 10.0)
    }
    
    func testImageFiltering() {
        // Create a test image
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContext(size)
        UIColor.purple.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let testImage = UIGraphicsGetImageFromCurrentImageContext() else {
            XCTFail("Failed to create test image")
            return
        }
        UIGraphicsEndImageContext()
        
        // Test each filter
        let filters: [ImageFilter] = [.none, .mono, .vibrant, .sepia]
        
        for filter in filters {
            let filteredImage = viewModel.applyFilter(testImage, filter: filter)
            XCTAssertNotNil(filteredImage, "Filtered image should not be nil for filter: \(filter)")
            
            if filter != .none {
                // Compare with original image
                let originalData = testImage.jpegData(compressionQuality: 1.0)
                let filteredData = filteredImage?.jpegData(compressionQuality: 1.0)
                XCTAssertNotEqual(originalData, filteredData, "Filtered image should be different from original for filter: \(filter)")
            }
        }
    }
} 
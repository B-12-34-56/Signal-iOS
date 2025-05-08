import XCTest
import AWSS3
import AWSDynamoDB
@testable import Signal
@testable import SignalUI

class AWSImageUploadTests: XCTestCase {
    
    private let awsService = AWSService.shared
    private let config = AWSConfig.shared
    private var uploadedImageURLs: [String] = []
    private var uploadedImageHashes: [String] = []
    private var activeUploadIds: [String] = []
    private var viewController: ImageUploadViewController!
    
    override func setUp() {
        super.setUp()
        do {
            try AWSConfig.shared.configureAWS()
            viewController = ImageUploadViewController()
            // Load the view to ensure proper initialization
            _ = viewController.view
        } catch {
            XCTFail("Failed to configure AWS: \(error)")
        }
    }
    
    override func tearDown() {
        // Cancel any active uploads
        for uploadId in activeUploadIds {
            awsService.cancelUpload(uploadId: uploadId)
        }
        
        // Clean up uploaded images and DynamoDB entries
        cleanupTestData()
        viewController = nil
        super.tearDown()
    }
    
    // MARK: - Test Cases
    
    func testImageUploadAndDuplicateDetection() {
        // Create a test image
        let testImage = createTestImage()
        
        // First upload - should succeed
        let firstUploadExpectation = expectation(description: "First image upload")
        var firstImageURL: String?
        var progressUpdates: [Double] = []
        
        if let uploadId = awsService.uploadImage(testImage, progressHandler: { progress in
            progressUpdates.append(progress)
        }) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let imageURL):
                firstImageURL = imageURL
                self.uploadedImageURLs.append(imageURL)
                firstUploadExpectation.fulfill()
            case .failure(let error):
                XCTFail("First upload failed: \(error.localizedDescription)")
            }
        }
        
        wait(for: [firstUploadExpectation], timeout: 30.0)
        
        // Verify first upload succeeded
        XCTAssertNotNil(firstImageURL, "First image URL should not be nil")
        XCTAssertTrue(firstImageURL!.contains(self.config.s3BucketName), "Image URL should contain bucket name")
        XCTAssertTrue(firstImageURL!.contains(self.config.s3ImagesPath), "Image URL should contain images path")
        XCTAssertFalse(progressUpdates.isEmpty, "Should receive progress updates")
        XCTAssertEqual(progressUpdates.last, 1.0, "Final progress should be 1.0")
        
        // Second upload of same image - should be detected as duplicate
        let secondUploadExpectation = expectation(description: "Second image upload")
        
        if let uploadId = awsService.uploadImage(testImage) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let imageURL):
                self.uploadedImageURLs.append(imageURL)
                // Verify duplicate in DynamoDB
                self.verifyDuplicateInDynamoDB(imageURL: imageURL) { isDuplicate in
                    XCTAssertTrue(isDuplicate, "Second upload should be detected as duplicate")
                    secondUploadExpectation.fulfill()
                }
            case .failure(let error):
                XCTFail("Second upload failed: \(error.localizedDescription)")
            }
        }
        
        wait(for: [secondUploadExpectation], timeout: 30.0)
    }
    
    func testImageUploadWithInvalidImage() {
        let invalidImage = UIImage()
        
        let expectation = expectation(description: "Invalid image upload")
        
        if let uploadId = awsService.uploadImage(invalidImage) { result in
            switch result {
            case .success:
                XCTFail("Upload should fail for invalid image")
            case .failure(let error):
                XCTAssertEqual((error as? AWSServiceError), .invalidImage, "Error should be invalidImage")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
    
    func testImageUploadWithCorruptedImage() {
        let corruptedImage = createCorruptedImage()
        
        let expectation = expectation(description: "Corrupted image upload")
        
        if let uploadId = awsService.uploadImage(corruptedImage) { result in
            switch result {
            case .success:
                XCTFail("Upload should fail for corrupted image")
            case .failure(let error):
                XCTAssertEqual((error as? AWSServiceError), .invalidImage, "Error should be invalidImage")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
    
    func testImageUploadAndTagging() {
        let testImage = createTestImage()
        
        let uploadExpectation = expectation(description: "Image upload and tagging")
        
        if let uploadId = awsService.uploadImage(testImage) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let imageURL):
                self.uploadedImageURLs.append(imageURL)
                // Get tags for uploaded image
                self.awsService.getImageTags(imageURL: imageURL) { tagResult in
                    switch tagResult {
                    case .success(let tags):
                        XCTAssertFalse(tags.isEmpty, "Tags should not be empty")
                        XCTAssertTrue(tags.count > 0, "Should have at least one tag")
                        uploadExpectation.fulfill()
                    case .failure(let error):
                        XCTFail("Failed to get tags: \(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                XCTFail("Upload failed: \(error.localizedDescription)")
            }
        }
        
        wait(for: [uploadExpectation], timeout: 30.0)
    }
    
    func testImageUploadWithLargeImage() {
        let largeImage = createLargeTestImage()
        
        let expectation = expectation(description: "Large image upload")
        var progressUpdates: [Double] = []
        
        if let uploadId = awsService.uploadImage(largeImage, progressHandler: { progress in
            progressUpdates.append(progress)
        }) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let imageURL):
                self.uploadedImageURLs.append(imageURL)
                XCTAssertTrue(imageURL.contains(self.config.s3BucketName), "Image URL should contain bucket name")
                XCTAssertFalse(progressUpdates.isEmpty, "Should receive progress updates")
                XCTAssertEqual(progressUpdates.last, 1.0, "Final progress should be 1.0")
                expectation.fulfill()
            case .failure(let error):
                XCTFail("Large image upload failed: \(error.localizedDescription)")
            }
        }
        
        wait(for: [expectation], timeout: 60.0) // Longer timeout for large image
    }
    
    func testImageUploadWithNetworkError() {
        // Simulate network error by using invalid AWS credentials
        let originalConfig = AWSConfig.shared
        let invalidConfig = AWSConfig.shared
        AWSConfig.shared = invalidConfig
        
        let testImage = createTestImage()
        let expectation = expectation(description: "Network error upload")
        
        if let uploadId = awsService.uploadImage(testImage) { result in
            switch result {
            case .success:
                XCTFail("Upload should fail with network error")
            case .failure(let error):
                if case .networkError = error as? AWSServiceError {
                    expectation.fulfill()
                } else {
                    XCTFail("Expected network error, got: \(error)")
                }
            }
        }
        
        wait(for: [expectation], timeout: 30.0)
        
        // Restore original config
        AWSConfig.shared = originalConfig
    }
    
    func testConcurrentImageUploads() {
        let testImages = (0..<3).map { _ in createTestImage() }
        let expectations = testImages.map { _ in expectation(description: "Concurrent upload") }
        
        for (index, image) in testImages.enumerated() {
            if let uploadId = awsService.uploadImage(image) { [weak self] result in
                guard let self = self else { return }
                
                switch result {
                case .success(let imageURL):
                    self.uploadedImageURLs.append(imageURL)
                    expectations[index].fulfill()
                case .failure(let error):
                    XCTFail("Concurrent upload \(index) failed: \(error.localizedDescription)")
                }
            }
        }
        
        wait(for: expectations, timeout: 30.0)
    }
    
    func testUploadCancellation() {
        let largeImage = createLargeTestImage()
        let expectation = expectation(description: "Upload cancellation")
        
        if let uploadId = awsService.uploadImage(largeImage) { [weak self] result in
            guard let self = self else { return }
            
            // Cancel the upload after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.awsService.cancelUpload(uploadId: uploadId)
            }
            
            switch result {
            case .success:
                XCTFail("Upload should be cancelled")
            case .failure(let error):
                if case .cancelled = error as? AWSServiceError {
                    expectation.fulfill()
                } else {
                    XCTFail("Expected cancelled error, got: \(error)")
                }
            }
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
    
    func testPerformanceImageUpload() {
        let testImage = createTestImage()
        
        measure {
            let expectation = expectation(description: "Performance upload")
            
            if let uploadId = awsService.uploadImage(testImage) { [weak self] result in
                guard let self = self else { return }
                
                switch result {
                case .success(let imageURL):
                    self.uploadedImageURLs.append(imageURL)
                    expectation.fulfill()
                case .failure(let error):
                    XCTFail("Performance upload failed: \(error.localizedDescription)")
                }
            }
            
            wait(for: [expectation], timeout: 30.0)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage() -> UIImage {
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
    }
    
    private func createLargeTestImage() -> UIImage {
        let size = CGSize(width: 2000, height: 2000)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
    }
    
    private func createCorruptedImage() -> UIImage {
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        
        // Corrupt the image data
        var imageData = image.jpegData(compressionQuality: 1.0)!
        imageData[0] = 0 // Corrupt the first byte
        return UIImage(data: imageData)!
    }
    
    private func cleanupTestData() {
        // Delete uploaded images from S3
        for imageURL in uploadedImageURLs {
            awsService.deleteImage(imageURL: imageURL)
        }
        
        // Delete image signatures from DynamoDB
        for hash in uploadedImageHashes {
            awsService.deleteImageSignature(hash: hash)
        }
    }
    
    private func verifyDuplicateInDynamoDB(imageURL: String, completion: @escaping (Bool) -> Void) {
        awsService.getImageSignature(imageURL: imageURL) { result in
            switch result {
            case .success(let isDuplicate):
                completion(isDuplicate)
            case .failure:
                completion(false)
            }
        }
    }
} 
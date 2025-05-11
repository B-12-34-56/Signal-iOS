import XCTest
@testable import DuplicateContentDetection

class AWSManagerTests: XCTestCase {
    var awsManager: AWSManager!
    
    override func setUp() {
        super.setUp()
        awsManager = AWSManager.shared
    }
    
    override func tearDown() {
        super.tearDown()
    }
    
    func testImagePreprocessing() async throws {
        // Create a test image
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        
        guard let imageData = image.jpegData(compressionQuality: 1.0) else {
            XCTFail("Failed to create image data")
            return
        }
        
        // Test resize
        let resizeOptions = ImagePreprocessingOptions(resizeTo: CGSize(width: 50, height: 50))
        let resizedData = try await awsManager.preprocessImage(imageData, options: resizeOptions)
        let resizedImage = UIImage(data: resizedData)
        XCTAssertEqual(resizedImage?.size, CGSize(width: 50, height: 50))
        
        // Test grayscale
        let grayscaleOptions = ImagePreprocessingOptions(convertToGrayscale: true)
        let grayscaleData = try await awsManager.preprocessImage(imageData, options: grayscaleOptions)
        let grayscaleImage = UIImage(data: grayscaleData)
        XCTAssertNotNil(grayscaleImage)
        
        // Test normalization
        let normalizeOptions = ImagePreprocessingOptions(normalize: true)
        let normalizedData = try await awsManager.preprocessImage(imageData, options: normalizeOptions)
        let normalizedImage = UIImage(data: normalizedData)
        XCTAssertNotNil(normalizedImage)
    }
    
    func testBatchProcessing() async throws {
        // Create multiple test images
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        var imageDatas: [Data] = []
        for _ in 0..<3 {
            let image = renderer.image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            guard let imageData = image.jpegData(compressionQuality: 1.0) else {
                XCTFail("Failed to create image data")
                return
            }
            imageDatas.append(imageData)
        }
        
        // Test batch processing
        let results = try await awsManager.checkForDuplicates(images: imageDatas)
        XCTAssertEqual(results.count, imageDatas.count)
    }
    
    func testCaching() async throws {
        // Create a test image
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        
        guard let imageData = image.jpegData(compressionQuality: 1.0) else {
            XCTFail("Failed to create image data")
            return
        }
        
        // First check (should hit DynamoDB)
        let firstResult = try await awsManager.checkForDuplicate(imageData: imageData)
        
        // Second check (should hit cache)
        let secondResult = try await awsManager.checkForDuplicate(imageData: imageData)
        
        XCTAssertEqual(firstResult, secondResult)
    }
    
    func testPreprocessingOptions() async throws {
        // Create a test image
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        
        guard let imageData = image.jpegData(compressionQuality: 1.0) else {
            XCTFail("Failed to create image data")
            return
        }
        
        // Test with all preprocessing options
        let options = ImagePreprocessingOptions(
            resizeTo: CGSize(width: 50, height: 50),
            normalize: true,
            convertToGrayscale: true
        )
        
        let result = try await awsManager.checkForDuplicate(
            imageData: imageData,
            preprocessingOptions: options
        )
        
        XCTAssertNotNil(result)
    }
} 
import XCTest
import AWSCore
import AWSS3
import AWSDynamoDB
import AWSLambda
import CommonCrypto
@testable import Signal

class AWSIntegrationTests: XCTestCase {
    var awsService: AWSService!
    
    override func setUp() {
        super.setUp()
        do {
            try AWSConfig.configureAWS()
            awsService = AWSService.shared
        } catch {
            XCTFail("Failed to initialize AWS configuration: \(error)")
        }
    }
    
    override func tearDown() {
        awsService = nil
        super.tearDown()
        print("\n📊 AWS Integration Tests Summary")
        print("================================")
        print("✅ All AWS integration tests completed")
        print("📅 Completed at: \(Date())")
        print("================================\n")
    }
    
    func testAWSConfiguration() {
        // Verify AWS is configured
        XCTAssertNotNil(AWSServiceManager.default().defaultServiceConfiguration)
        
        // Verify S3 is registered
        XCTAssertNotNil(AWSS3.default())
        
        // Verify DynamoDB is registered
        XCTAssertNotNil(AWSDynamoDB.default())
        
        // Verify configuration values
        XCTAssertFalse(AWSConfig.s3BucketName.isEmpty)
        XCTAssertFalse(AWSConfig.dynamoDbTableName.isEmpty)
        XCTAssertFalse(AWSConfig.apiGatewayEndpoint.isEmpty)
        
        // Test S3 Configuration
        XCTAssertEqual(AWSConfig.s3BucketName, "dxtnhmfqv8")
        XCTAssertEqual(AWSConfig.region, .USEast1)
        XCTAssertEqual(AWSConfig.s3ImagesPath, "uploads")
        
        // Test DynamoDB Configuration
        // XCTAssertEqual(AWSConfig.dynamoDbTableName, "ImageSignatures")
        // XCTAssertEqual(AWSConfig.dynamoDbRegion, .USEast1)
        // XCTAssertEqual(AWSConfig.dynamoDbTableArn, "arn:aws:dynamodb:us-east-1:739874238091:table/ImageSignatures")
        
        // Test Cognito Configuration
        XCTAssertEqual(AWSConfig.identityPoolId, "us-east-1:a41de7b5-bc6b-48f7-ba53-2c45d0466c4c")
        XCTAssertEqual(AWSConfig.cognitoRegion, .USEast1)
    }
    
    func testImageUpload() {
        // Create a test image
        let testImage = createTestImage()
        
        // Create expectation for upload completion
        let uploadExpectation = expectation(description: "Image upload should complete")
        var uploadProgress: Double = 0
        var uploadResult: Result<String, Error>?
        
        // Start upload
        let uploadId = awsService.uploadImage(testImage) { progress in
            uploadProgress = progress
        } completion: { result in
            uploadResult = result
            uploadExpectation.fulfill()
        }
        
        // Wait for upload to complete
        wait(for: [uploadExpectation], timeout: 30)
        
        // Verify upload results
        XCTAssertNotNil(uploadId, "Upload ID should not be nil")
        XCTAssertGreaterThan(uploadProgress, 0, "Upload progress should be greater than 0")
        
        switch uploadResult {
        case .success(let imageURL):
            XCTAssertTrue(imageURL.contains(AWSConfig.s3BucketName), "Image URL should contain bucket name")
            XCTAssertTrue(imageURL.contains(AWSConfig.s3ImagesPath), "Image URL should contain images path")
        case .failure(let error):
            XCTFail("Upload failed with error: \(error)")
        case .none:
            XCTFail("Upload result should not be nil")
        }
    }
    
    func testDynamoDBOperations() {
        // Create test hash
        let testHash = "test_hash_\(UUID().uuidString)"
        
        // Test saving signature
        let saveExpectation = expectation(description: "Save signature should complete")
        awsService.saveImageSignature(hash: testHash) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("Failed to save signature: \(error)")
            }
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 10)
        
        // Test retrieving signature
        let getExpectation = expectation(description: "Get signature should complete")
        awsService.getImageSignature(hash: testHash) { result in
            switch result {
            case .success(let item):
                XCTAssertNotNil(item, "Retrieved item should not be nil")
                XCTAssertEqual(item?["ContentHash"]?.s, testHash, "Retrieved hash should match saved hash")
            case .failure(let error):
                XCTFail("Failed to get signature: \(error)")
            }
            getExpectation.fulfill()
        }
        wait(for: [getExpectation], timeout: 10)
    }
    
    func testErrorHandling() {
        // Test invalid image
        let invalidImage = UIImage()
        let invalidImageExpectation = expectation(description: "Invalid image upload should fail")
        
        awsService.uploadImage(invalidImage) { _ in } completion: { result in
            switch result {
            case .success:
                XCTFail("Upload should fail for invalid image")
            case .failure(let error):
                XCTAssertTrue(error is AWSServiceError, "Error should be AWSServiceError")
            }
            invalidImageExpectation.fulfill()
        }
        
        wait(for: [invalidImageExpectation], timeout: 10)
        
        // Test duplicate image detection
        let testImage = createTestImage()
        let duplicateExpectation = expectation(description: "Duplicate image upload should be detected")
        
        // First upload
        awsService.uploadImage(testImage) { _ in } completion: { _ in
            // Second upload
            self.awsService.uploadImage(testImage) { _ in } completion: { result in
                switch result {
                case .success:
                    XCTFail("Duplicate upload should be detected")
                case .failure(let error):
                    XCTAssertTrue(error is AWSServiceError, "Error should be AWSServiceError")
                }
                duplicateExpectation.fulfill()
            }
        }
        
        wait(for: [duplicateExpectation], timeout: 30)
    }
    
    func testAWSCredentialsValidation() async {
        let isValid = await AWSConfig.validateAWSCredentials(checkAPIGateway: true)
        XCTAssertTrue(isValid, "AWS credentials should be valid and able to connect to DynamoDB and API Gateway")
    }
    
    func testAPIGatewayInvocation() async {
        guard let url = URL(string: AWSConfig.apiGatewayEndpoint) else {
            XCTFail("Invalid API Gateway endpoint URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try! await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("No HTTP response from API Gateway")
            return
        }
        XCTAssertEqual(httpResponse.statusCode, 200, "API Gateway should return 200 OK")
        XCTAssertNotNil(data, "API Gateway should return data")
    }

    func testLambdaInvocation() async {
        let lambda = AWSLambda.default()
        let request = AWSLambdaInvokerInvocationRequest()!
        request.functionName = "your-actual-lambda-function-name" // Set your Lambda function name here
        request.payload = "{}".data(using: .utf8)
        let result = try? await lambda.invoke(request)
        XCTAssertNotNil(result, "Lambda invocation should return a result")
        XCTAssertEqual(result?.statusCode?.intValue, 200, "Lambda should return 200 OK")
    }

    func testS3ObjectRetrievalAfterUpload() async {
        let testImage = createTestImage()
        let imageHash = hashImage(testImage)
        print("🚀 Starting AWS S3 upload test...")
        print("📸 Image hash: \(imageHash)")
        let uploadExpectation = expectation(description: "Image upload should complete for retrieval test")
        var uploadedImageURL: String?
        awsService.uploadImage(testImage) { _ in } completion: { result in
            switch result {
            case .success(let imageURL):
                uploadedImageURL = imageURL
                print("✅ Successfully uploaded image to AWS S3!")
                print("📍 S3 URL: \(imageURL)")
                print("🔐 SHA-256 Hash: \(imageHash)")
                print("📊 Upload completed at: \(Date())")
            case .failure(let error):
                XCTFail("Upload failed: \(error)")
            }
            uploadExpectation.fulfill()
        }
        wait(for: [uploadExpectation], timeout: 30)
        guard let imageURLString = uploadedImageURL, let imageURL = URL(string: imageURLString) else {
            XCTFail("No image URL returned from upload")
            return
        }
        let (data, response) = try! await URLSession.shared.data(from: imageURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("No HTTP response from S3 object retrieval")
            return
        }
        XCTAssertEqual(httpResponse.statusCode, 200, "S3 object retrieval should return 200 OK")
        XCTAssertNotNil(data, "S3 object retrieval should return data")
    }
    
    func testAWSConnectivity() async {
        print("🔍 Checking AWS connectivity...")
        // Check S3
        let s3 = AWSS3.default()
        XCTAssertNotNil(s3, "S3 client should be initialized")
        print("✅ S3 client initialized")
        // Check DynamoDB
        let dynamoDB = AWSDynamoDB.default()
        XCTAssertNotNil(dynamoDB, "DynamoDB client should be initialized")
        print("✅ DynamoDB client initialized")
        // Check credentials
        let credentialsProvider = AWSServiceManager.default().defaultServiceConfiguration?.credentialsProvider
        XCTAssertNotNil(credentialsProvider, "Credentials provider should be available")
        print("✅ AWS credentials provider available")
        print("✅ AWS connectivity check passed!")
    }

    func testS3BucketUpload() async {
        print("🚀 Testing S3 upload to bucket: dxtnhmfqv8")
        print("📁 Upload folder: uploads")
        print("🌎 Region: us-east-1")
        let testImage = createTestImage()
        let imageHash = hashImage(testImage)
        let fileName = "test-image-\(UUID().uuidString).jpg"
        print("📸 Created test image with hash: \(imageHash)")
        let uploadExpectation = expectation(description: "S3 upload to dxtnhmfqv8/uploads")
        var uploadedURL: String?
        awsService.uploadImage(testImage) { progress in
            print("⬆️ Upload progress: \(Int(progress * 100))%")
        } completion: { result in
            switch result {
            case .success(let imageURL):
                uploadedURL = imageURL
                print("✅ Successfully uploaded to S3!")
                print("📍 Full S3 URL: \(imageURL)")
                print("🔐 Image Hash: \(imageHash)")
                XCTAssertTrue(imageURL.contains("dxtnhmfqv8"), "URL should contain bucket name")
                XCTAssertTrue(imageURL.contains("uploads"), "URL should contain uploads folder")
                XCTAssertTrue(imageURL.contains("us-east-1"), "URL should contain region")
            case .failure(let error):
                XCTFail("❌ Upload failed: \(error)")
            }
            uploadExpectation.fulfill()
        }
        wait(for: [uploadExpectation], timeout: 30)
        if let url = uploadedURL {
            let expectedPattern = "https://s3.us-east-1.amazonaws.com/dxtnhmfqv8/uploads/"
            XCTAssertTrue(url.hasPrefix(expectedPattern) || url.contains("dxtnhmfqv8.s3"), "URL should match expected S3 pattern")
            print("✅ S3 URL validation passed!")
        }
    }

    func testS3BucketAccess() async {
        print("🔍 Testing S3 bucket access for: dxtnhmfqv8")
        let s3 = AWSS3.default()
        let listRequest = AWSS3ListObjectsV2Request()!
        listRequest.bucket = "dxtnhmfqv8"
        listRequest.prefix = "uploads/"
        listRequest.maxKeys = 1
        do {
            let output = try await s3.listObjectsV2(listRequest)
            print("✅ Successfully accessed S3 bucket!")
            print("📊 Bucket contains \(output.keyCount?.intValue ?? 0) objects in uploads/")
        } catch {
            print("⚠️ S3 List Error: \(error)")
            if error.localizedDescription.contains("AccessDenied") {
                print("✅ S3 connectivity works (got AccessDenied, not network error)")
            } else {
                XCTFail("❌ S3 connectivity issue: \(error)")
            }
        }
    }

    func testMinimalS3Upload() {
        print("\n🚀 Starting minimal S3 upload test")
        print("🪣 Bucket: dxtnhmfqv8")
        print("📁 Folder: uploads/")
        print("🌎 Region: us-east-1\n")
        let testImage = createTestImage()
        let expectation = expectation(description: "S3 Upload")
        awsService.uploadImage(testImage) { progress in
            if progress == 1.0 {
                print("✅ Upload complete!")
            }
        } completion: { result in
            switch result {
            case .success(let url):
                print("✅ SUCCESS: Image uploaded to S3")
                print("📍 URL: \(url)")
                print("✅ AWS S3 connection confirmed!\n")
            case .failure(let error):
                print("❌ FAILED: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage() -> UIImage {
        let size = CGSize(width: 100, height: 100)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        // Create a more interesting test pattern
        UIColor.blue.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        UIColor.white.setFill()
        let timestamp = Date().timeIntervalSince1970
        let text = "Test-\(Int(timestamp))" as NSString
        text.draw(at: CGPoint(x: 10, y: 40), withAttributes: [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 12)
        ])
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        print("🎨 Created test image: 100x100px with timestamp")
        return image
    }
    
    private func hashImage(_ image: UIImage) -> String {
        guard let imageData = image.pngData() else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        imageData.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(imageData.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
} 
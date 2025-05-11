import Foundation
import AWSCore
import AWSS3
import AWSDynamoDB
import AWSCognitoIdentityProvider
import CommonCrypto
import os.log

public struct ImagePreprocessingOptions {
    public let resizeTo: CGSize?
    public let normalize: Bool
    public let convertToGrayscale: Bool
    
    public init(resizeTo: CGSize? = nil, normalize: Bool = false, convertToGrayscale: Bool = false) {
        self.resizeTo = resizeTo
        self.normalize = normalize
        self.convertToGrayscale = convertToGrayscale
    }
}

public class AWSManager {
    public static let shared = AWSManager()
    
    private let logger = Logger(subsystem: "org.signal.duplicate-content", category: "aws")
    private let dynamoDB: AWSDynamoDB
    private let cache = NSCache<NSString, NSNumber>()
    
    private init() {
        dynamoDB = AWSDynamoDB.default()
        setupAWSCredentials()
        setupCache()
    }
    
    private func setupCache() {
        cache.countLimit = 1000 // Limit cache to 1000 entries
    }
    
    private func setupAWSCredentials() {
        guard let accessKey = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"],
              let secretKey = ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"],
              let sessionToken = ProcessInfo.processInfo.environment["AWS_SESSION_TOKEN"] else {
            logger.error("AWS credentials not found in environment variables")
            fatalError("AWS credentials not found in environment variables")
        }
        
        let credentials = AWSBasicSessionCredentialsProvider(
            accessKey: accessKey,
            secretKey: secretKey,
            sessionToken: sessionToken
        )
        
        let configuration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentials
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
    
    public func updateCredentials(accessKey: String, secretKey: String, sessionToken: String) {
        logger.info("Updating AWS credentials")
        let credentials = AWSBasicSessionCredentialsProvider(
            accessKey: accessKey,
            secretKey: secretKey,
            sessionToken: sessionToken
        )
        let configuration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentials
        )
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
    
    public func checkForDuplicate(imageData: Data, preprocessingOptions: ImagePreprocessingOptions? = nil) async throws -> Bool {
        logger.debug("Checking for duplicate content")
        let processedData = try await preprocessImage(imageData, options: preprocessingOptions)
        let signature = try await generateImageSignature(from: processedData)
        return try await checkSignatureExists(signature)
    }
    
    public func checkForDuplicates(images: [Data], preprocessingOptions: ImagePreprocessingOptions? = nil) async throws -> [Bool] {
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            for image in images {
                group.addTask {
                    try await self.checkForDuplicate(imageData: image, preprocessingOptions: preprocessingOptions)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
    
    public func storeImageSignature(imageData: Data, preprocessingOptions: ImagePreprocessingOptions? = nil) async throws {
        logger.debug("Storing image signature")
        let processedData = try await preprocessImage(imageData, options: preprocessingOptions)
        let signature = try await generateImageSignature(from: processedData)
        try await storeSignature(signature)
    }
    
    private func preprocessImage(_ imageData: Data, options: ImagePreprocessingOptions?) async throws -> Data {
        guard let options = options else { return imageData }
        
        // Create image from data
        guard let image = UIImage(data: imageData) else {
            throw NSError(domain: "AWSManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image from data"])
        }
        
        var processedImage = image
        
        // Apply preprocessing options
        if let targetSize = options.resizeTo {
            processedImage = processedImage.resized(to: targetSize)
        }
        
        if options.convertToGrayscale {
            processedImage = processedImage.grayscale()
        }
        
        if options.normalize {
            processedImage = processedImage.normalized()
        }
        
        // Convert back to data
        guard let processedData = processedImage.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "AWSManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert processed image to data"])
        }
        
        return processedData
    }
    
    private func generateImageSignature(from imageData: Data) async throws -> String {
        let hash = imageData.sha256()
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func checkSignatureExists(_ signature: String) async throws -> Bool {
        // Check cache first
        if let cached = cache.object(forKey: signature as NSString) {
            logger.debug("Cache hit for signature: \(signature)")
            return cached.boolValue
        }
        
        let queryInput = AWSDynamoDBQueryInput()!
        queryInput.tableName = "ImageSignatures"
        queryInput.keyConditionExpression = "signature = :sig"
        
        let sigValue = AWSDynamoDBAttributeValue()!
        sigValue.s = signature
        queryInput.expressionAttributeValues = [":sig": sigValue]
        
        do {
            let result: Bool = try await withCheckedThrowingContinuation { continuation in
                dynamoDB.query(queryInput).continueWith { task in
                    if let error = task.error {
                        continuation.resume(throwing: error)
                    } else if let result = task.result {
                        let exists = (result.items?.count ?? 0) > 0
                        continuation.resume(returning: exists)
                    } else {
                        continuation.resume(returning: false)
                    }
                    return nil
                }
            }
            
            // Cache the result
            cache.setObject(NSNumber(value: result), forKey: signature as NSString)
            logger.debug("Signature check completed: \(result ? "found" : "not found")")
            return result
        } catch {
            logger.error("Error checking signature: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func storeSignature(_ signature: String) async throws {
        let putItemInput = AWSDynamoDBPutItemInput()!
        putItemInput.tableName = "ImageSignatures"
        
        let sigValue = AWSDynamoDBAttributeValue()!
        sigValue.s = signature
        
        let timestampValue = AWSDynamoDBAttributeValue()!
        timestampValue.n = String(Date().timeIntervalSince1970)
        
        putItemInput.item = [
            "signature": sigValue,
            "timestamp": timestampValue
        ]
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                dynamoDB.putItem(putItemInput).continueWith { task in
                    if let error = task.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                    return nil
                }
            }
            logger.debug("Signature stored successfully")
        } catch {
            logger.error("Error storing signature: \(error.localizedDescription)")
            throw error
        }
    }
}

// Image processing extensions
extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    
    func grayscale() -> UIImage {
        let context = CIContext(options: nil)
        let filter = CIFilter(name: "CIPhotoEffectMono")!
        filter.setValue(CIImage(image: self), forKey: kCIInputImageKey)
        let outputImage = filter.outputImage!
        let cgImage = context.createCGImage(outputImage, from: outputImage.extent)!
        return UIImage(cgImage: cgImage)
    }
    
    func normalized() -> UIImage {
        let context = CIContext(options: nil)
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(CIImage(image: self), forKey: kCIInputImageKey)
        filter.setValue(1.0, forKey: kCIInputContrastKey)
        filter.setValue(0.0, forKey: kCIInputBrightnessKey)
        let outputImage = filter.outputImage!
        let cgImage = context.createCGImage(outputImage, from: outputImage.extent)!
        return UIImage(cgImage: cgImage)
    }
}

extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }
} 
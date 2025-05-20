import Foundation
import AWSS3
import AWSCore
import SignalServiceKit

public enum FilterResult {
    case allowed(tags: [String])
    case blocked(reason: String, tags: [String])
    case error(Error?)
}

@objc
public class ContentFilterService: NSObject {
    @objc
    public static let shared = ContentFilterService()
    
    private override init() {
        super.init()
        configureAWS()
    }
    
    private func configureAWS() {
        guard let poolID = Bundle.main.object(forInfoDictionaryKey: "AWSContentFilterPoolID") as? String else {
            owsFailDebug("Missing AWSContentFilterPoolID in Info.plist")
            return
        }
        
        let credentialsProvider = AWSCognitoCredentialsProvider(region: .USEast1, identityPoolId: poolID)
        let configuration = AWSServiceConfiguration(region: .USEast1, credentialsProvider: credentialsProvider)
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
    
    private func computeMD5(data: Data) -> String {
        let length = Int(CC_MD5_DIGEST_LENGTH)
        var digest = [UInt8](repeating: 0, count: length)
        _ = data.withUnsafeBytes { body in
            CC_MD5(body.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
    
    @objc
    public func scanAndUpload(imageData: Data, fileName: String, completion: @escaping (FilterResult) -> Void) {
        // 1. Compute a unique key for the image
        let imageHash = computeMD5(data: imageData)
        let s3Key = "image-test/\(imageHash).jpg"
        
        // 2. Upload to S3 bucket
        let expression = AWSS3TransferUtilityUploadExpression()
        let transferUtility = AWSS3TransferUtility.default()
        
        transferUtility.uploadData(imageData,
                                 bucket: "filter-slide",
                                 key: s3Key,
                                 contentType: "image/jpeg",
                                 expression: expression) { task, error in
            if let error = error {
                Logger.error("ContentFilter: S3 upload failed: \(error)")
                completion(.error(error))
                return
            }
            
            // 3. After successful upload, call the content analysis service
            self.requestImageTags(forKey: s3Key) { result in
                completion(result)
            }
        }
    }
    
    private func requestImageTags(forKey key: String, completion: @escaping (FilterResult) -> Void) {
        guard let apiURL = URL(string: "https://YOUR_API_ENDPOINT?key=\(key)") else {
            completion(.error(nil))
            return
        }
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.error(error))
                return
            }
            
            guard let data = data,
                  let resultJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.error(nil))
                return
            }
            
            // Parse tags or message from JSON response
            let tags = resultJSON["tags"] as? [String] ?? []
            let message = resultJSON["message"] as? String ?? ""
            
            // Determine if blocked due to duplicate or disallowed content
            if message.contains("Duplicate image detected") {
                completion(.blocked(reason: "Duplicate image detected.", tags: tags))
            } else if tags.contains("explicit") || tags.contains("violence") {
                completion(.blocked(reason: "Prohibited content detected.", tags: tags))
            } else {
                completion(.allowed(tags: tags))
            }
        }.resume()
    }
} 
import Foundation
import AWSS3

public final class AWSServiceManager {
    public static let shared = AWSServiceManager()
    private init() { configureSDK() }

    private let bucket = Bundle.main.object(forInfoDictionaryKey: "S3_BUCKET_NAME") as? String ?? ""

    // MARK: – Public API ------------------------------------------------------

    public func uploadImageData(_ data: Data,
                              key: String,
                              completion: @escaping (Result<Void, Error>) -> Void) {

        let expr = AWSS3TransferUtilityUploadExpression()
        expr.progressBlock = { _, progress in
            // Optional: Forward progress with Combine/NotificationCenter.
            NotificationCenter.default.post(name: .awsUploadProgress,
                                         object: key,
                                         userInfo: ["fraction": progress.fractionCompleted])
        }

        AWSS3TransferUtility.default().uploadData(
            data,
            bucket: bucket,
            key: key,
            contentType: "application/octet-stream",   // encrypted blob
            expression: expr)
        { task, err in
            DispatchQueue.main.async {
                if let e = err { completion(.failure(e)) }
                else           { completion(.success(())) }
            }
        }
    }

    public func deleteImage(key: String, completion: @escaping (Error?) -> Void) {
        let req = AWSS3DeleteObjectRequest()!
        req.bucket = bucket
        req.key    = key
        AWSS3.default().deleteObject(req) { _, err in DispatchQueue.main.async { completion(err) } }
    }

    // MARK: – SDK bootstrap ---------------------------------------------------

    private func configureSDK() {
        guard AWSS3.default().configuration == nil else { return } // already bootstrapped

        let ak  = Bundle.main.object(forInfoDictionaryKey: "AWS_ACCESS_KEY")    as? String ?? ""
        let sk  = Bundle.main.object(forInfoDictionaryKey: "AWS_SECRET_KEY")    as? String ?? ""
        let reg = Bundle.main.object(forInfoDictionaryKey: "AWS_REGION")        as? String ?? "us-west-2"

        let provider = AWSStaticCredentialsProvider(accessKey: ak, secretKey: sk)
        let cfg      = AWSServiceConfiguration(region: .init(regionName: reg),
                                             credentialsProvider: provider)
        AWSServiceManager.default().defaultServiceConfiguration = cfg
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let awsUploadProgress = Notification.Name("awsUploadProgress")
} 
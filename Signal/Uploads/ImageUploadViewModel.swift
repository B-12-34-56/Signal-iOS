import UIKit
import SignalServiceKit

final class ImageUploadViewModel {
    enum UploadError: Int { case duplicate = -2 }

    func uploadImage(_ img: UIImage,
                    completion: @escaping (Result<String, Error>) -> Void) {

        // 1. hash
        guard let sha = gen.generateSignature(for: img),
              let ph = gen.generatePerceptualHash(for: img) else {
            return completion(.failure(NSError(domain: "hash", code: -1)))
        }

        // 2. duplicate check
        db.checkForDuplicate(signature: sha, perceptualHash: ph) { [weak self] dup in
            switch dup {
            case .failure(let e):
                completion(.failure(e))

            case .success(true):
                completion(.failure(NSError(domain: "ImageUpload",
                                          code: UploadError.duplicate.rawValue,
                                          userInfo: [NSLocalizedDescriptionKey:
                                                    "Duplicate image detected"])))

            case .success(false):
                self?.proceedUpload(img: img, sha: sha, ph: ph, completion: completion)
            }
        }
    }

    private func proceedUpload(img: UIImage,
                             sha: String,
                             ph: String,
                             completion: @escaping (Result<String, Error>) -> Void) {

        guard let data = img.jpegData(compressionQuality: 0.9) else {
            return completion(.failure(NSError(domain: "jpeg", code: -1)))
        }

        // Encrypt BEFORE S3 to stay Signal-style
        guard let enc = try? AttachmentEncryptor.encrypt(data: data) else {
            return completion(.failure(NSError(domain: "enc", code: -1)))
        }
        let key = "images/\(UUID().uuidString).bin"

        aws.uploadImageData(enc.ciphertext, key: key) { [weak self] upResult in
            switch upResult {
            case .failure(let e):
                completion(.failure(e))
            case .success:
                self?.db.storeSignature(signature: sha, perceptualHash: ph, imageKey: key) { store in
                    switch store {
                    case .success: completion(.success(key))
                    case .failure(let e):
                        AWSServiceManager.shared.deleteImage(key: key) { _ in }
                        completion(.failure(e))
                    }
                }
            }
        }
    }

    // MARK: Singletons
    private let gen = ImageSignatureGenerator.shared
    private let aws = AWSServiceManager.shared
    private let db = DynamoDBServiceManager.shared
} 
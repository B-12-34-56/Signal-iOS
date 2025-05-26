import Foundation
import AWSLambda
import AWSCore
import UIKit

public enum DuplicateFilterError: Error {
    case configuration(String)
    case processing(String)
    case network(String)
    case response(String)
}

@objc
public final class DuplicateFilterService: NSObject {
    @objc public static let shared = DuplicateFilterService()

    private let lambdaFunctionName: String
    private let threshold: Int
    private let lambdaARN = "arn:aws:lambda:us-east-1:123456789012:function:YourLambdaFunction" // <-- Hardcoded Lambda ARN

    private override init() {
        guard
            let fn = Bundle.main.object(forInfoDictionaryKey: "AWSContentFilterFunction") as? String,
            let th = Bundle.main.object(forInfoDictionaryKey: "DuplicateThreshold") as? Int
        else { fatalError("Missing AWS config in Info.plist") }

        lambdaFunctionName = fn
        threshold = th
        super.init()
    }

    public func checkDuplicate(
        image: UIImage,
        completion: @escaping (Result<Bool, Error>) -> Void) {

        // 1. Hash (async)
        ImageHashing.shared.computeHashesAsync(for: image) { hashes in
            guard let (sha, pHashStr) = hashes,
                  let pHash = pHashStr.flatMap({ UInt64($0, radix: 16) }) else {
                completion(.failure(DuplicateFilterError.processing("hash-fail"))); return
            }

            // 2. Local DB check (SHA-256 exact)
            if let _ = ImageHashDatabase.shared.checkSHA256(sha) {
                completion(.success(true))
                return
            }

            // 3. Local DB check (pHash near-duplicate)
            let all = ImageHashDatabase.shared.allPerceptualHashes()
            let threshold = self.threshold
            let isNearDuplicate = all.contains { rec in
                let dist = self.hammingDistance(pHash, rec.phash)
                return dist <= threshold
            }
            if isNearDuplicate {
                completion(.success(true))
                return
            }

            // 4. Payload for AWS
            let body: [String: Any] = ["sha256Hash": sha, "perceptualHash": pHashStr as Any]
            guard let json = try? JSONSerialization.data(withJSONObject: body) else {
                completion(.failure(DuplicateFilterError.processing("json-fail"))); return
            }

            // 5. Lambda request – unwrap optional
            guard let req = AWSLambdaInvokerInvocationRequest() else {
                completion(.failure(DuplicateFilterError.processing("request-nil"))); return
            }
            req.functionName = self.lambdaARN // <-- Use hardcoded ARN
            req.invocationType = .requestResponse
            req.payload = json

            AWSLambda.default().invoke(req).continueWith { task in
                if let err = task.error {
                    completion(.failure(DuplicateFilterError.network(err.localizedDescription)))
                    return nil
                }
                guard
                    let data = task.result?.payload as? Data,
                    let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let count = resp["duplicateCount"] as? Int
                else {
                    completion(.failure(DuplicateFilterError.response("parse-fail"))); return nil
                }

                // If not duplicate, save to local DB
                if count < self.threshold, let pHashStr = pHashStr, let pHash = UInt64(pHashStr, radix: 16) {
                    ImageHashDatabase.shared.saveHash(sha, phash: pHash, fileExtension: "jpg", s3URL: "", mimeType: "image/jpeg", fileSize: 0)
                }

                completion(.success(count >= self.threshold))
                return nil
            }
        }
    }

    public func checkDuplicate(image: UIImage) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            checkDuplicate(image: image) { cont.resume(with: $0) }
        }
    }

    // Utility: Hamming distance for 64-bit hashes
    private func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

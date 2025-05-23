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

        // 1. Hash
        guard let (sha, pHash) = ImageHashing.shared.computeHashes(for: image) else {
            completion(.failure(DuplicateFilterError.processing("hash-fail"))); return
        }

        // 2. Payload
        let body: [String: Any] = ["sha256Hash": sha, "perceptualHash": pHash as Any]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(DuplicateFilterError.processing("json-fail"))); return
        }

        // 3. Lambda request – unwrap optional
        guard let req = AWSLambdaInvokerInvocationRequest() else {
            completion(.failure(DuplicateFilterError.processing("request-nil"))); return
        }
        req.functionName = lambdaFunctionName
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

            completion(.success(count >= self.threshold))
            return nil
        }
    }

    public func checkDuplicate(image: UIImage) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            checkDuplicate(image: image) { cont.resume(with: $0) }
        }
    }
}

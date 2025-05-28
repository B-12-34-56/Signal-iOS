import Foundation
import AWSLambda
import AWSCore

public final class DuplicateFilterService {
    public enum FilterError: Error {
        case configuration(String)
        case lambda(Error)
        case badResponse
    }

    // MARK: – Dependencies
    private let lambda: AWSLambda
    private let functionName: String
    private let threshold: Int

    // MARK: – Init
    public init(lambda: AWSLambda = .default()) throws {
        guard
            let fn = Bundle.main.infoDictionary?["ContentFilterLambdaName"] as? String,
            !fn.isEmpty,
            let th = Bundle.main.infoDictionary?["DuplicateThreshold"] as? Int
        else { throw FilterError.configuration("Missing ContentFilterLambdaName or DuplicateThreshold") }

        self.lambda = lambda
        self.functionName = fn
        self.threshold = th
    }

    // MARK: – API
    /// `true` ⇒ message should be *blocked* (duplicate count > threshold)
    public func isDuplicate(_ hashes: (sha256: String, pHash: UInt64)) async throws -> Bool {
        var request = AWSLambdaInvokeRequest()!
        request.functionName = functionName
        request.payload = try JSONEncoder().encode([
            "sha256": hashes.sha256,
            "pHash": String(hashes.pHash),
            "userId": AWSCognitoCredentialsProvider.default().identityId ?? ""
        ])

        do {
            let response = try await lambda.invoke(request)
            guard
                let data = response.payload,
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let count = json["duplicateCount"] as? Int
            else { throw FilterError.badResponse }

            return count > threshold
        } catch {
            throw FilterError.lambda(error)
        }
    }
}

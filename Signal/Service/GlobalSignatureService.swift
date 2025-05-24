import Foundation

final class GlobalSignatureService {
    static let shared = GlobalSignatureService()
    private let db = DynamoDBServiceManager.shared

    func getS3Key(for hash: String) async -> String? {
        await db.getS3Key(for: hash)
    }

    func store(hash: String, s3Key: String) async -> Bool {
        await db.store(hash: hash, s3Key: s3Key)
    }
} 
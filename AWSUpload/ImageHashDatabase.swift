import Foundation
import GRDB

// GRDB-backed local hash database for deduplication
final class ImageHashDatabase {
    static let shared = ImageHashDatabase()
    private let dbQueue: DatabaseQueue
    
    struct ImageRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
        var id: Int64?
        let sha256: String
        let phash: UInt64
        let fileExtension: String
        let s3URL: String
        let mimeType: String
        let fileSize: Int64
        let uploadDate: Date
        static let databaseTableName = "image_fingerprint"
    }

    private init() {
        let dbURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("image_hashes.sqlite")
        dbQueue = try! DatabaseQueue(path: dbURL.path)
        try? dbQueue.write { db in
            try db.create(table: ImageRecord.databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sha256", .text).notNull().unique()
                t.column("phash", .integer).notNull()
                t.column("fileExtension", .text).notNull()
                t.column("s3URL", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("uploadDate", .datetime).notNull()
            }
        }
    }

    func checkSHA256(_ sha: String) -> ImageRecord? {
        try? dbQueue.read { db in
            try ImageRecord.filter(Column("sha256") == sha).fetchOne(db)
        }
    }

    func allPerceptualHashes() -> [ImageRecord] {
        (try? dbQueue.read { db in
            try ImageRecord.fetchAll(db)
        }) ?? []
    }

    func saveHash(_ sha: String, phash: UInt64, fileExtension: String, s3URL: String, mimeType: String, fileSize: Int64) {
        let record = ImageRecord(id: nil, sha256: sha, phash: phash, fileExtension: fileExtension, s3URL: s3URL, mimeType: mimeType, fileSize: fileSize, uploadDate: Date())
        _ = try? dbQueue.write { db in
            try record.insert(db)
        }
    }
} 
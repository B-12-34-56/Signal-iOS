import Foundation

// Simple local hash database for deduplication
// (Replace with GRDB/SQLite if available in your project)
final class ImageHashDatabase {
    static let shared = ImageHashDatabase()
    private let userDefaults = UserDefaults.standard
    private let persistentKey = "SignalImageHashes"
    
    struct ImageRecord: Codable {
        let hash: String
        let fileExtension: String
        let s3URL: String
        let mimeType: String
        let fileSize: Int64
        let uploadDate: Date
    }
    
    private var cache: [String: ImageRecord] = [:]
    
    private init() {
        load()
    }
    
    private func key(for hash: String, fileExtension: String) -> String {
        return "\(hash)_\(fileExtension)"
    }
    
    func checkHash(_ hash: String, fileExtension: String) -> ImageRecord? {
        return cache[key(for: hash, fileExtension: fileExtension)]
    }
    
    func saveHash(_ hash: String, fileExtension: String, s3URL: String, mimeType: String, fileSize: Int64) {
        let record = ImageRecord(hash: hash, fileExtension: fileExtension, s3URL: s3URL, mimeType: mimeType, fileSize: fileSize, uploadDate: Date())
        cache[key(for: hash, fileExtension: fileExtension)] = record
        persist()
    }
    
    private func load() {
        if let data = userDefaults.data(forKey: persistentKey),
           let dict = try? JSONDecoder().decode([String: ImageRecord].self, from: data) {
            cache = dict
        }
    }
    
    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            userDefaults.set(data, forKey: persistentKey)
        }
    }
} 
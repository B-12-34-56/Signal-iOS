import Foundation
import AWSCore

public class AWSServiceManager {
    public static let shared = AWSServiceManager()
    
    private init() {
        setupAWS()
    }
    
    private func setupAWS() {
        do {
            try GlobalEndpoints.configureAWS()
        } catch {
            Logger.error("Failed to configure AWS for duplicate content detection: \(error)")
        }
    }
    
    public func reconfigure() {
        setupAWS()
    }
} 
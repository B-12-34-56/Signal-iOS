import XCTest
@testable import DuplicateContentDetection

final class DuplicateDetectorTests: XCTestCase {
    var duplicateDetector: DuplicateDetector!
    var mockGlobalSignatureService: MockGlobalSignatureService!
    
    override func setUp() {
        super.setUp()
        mockGlobalSignatureService = MockGlobalSignatureService()
        duplicateDetector = DuplicateDetector()
    }
    
    override func tearDown() {
        duplicateDetector = nil
        mockGlobalSignatureService = nil
        super.tearDown()
    }
    
    func testIsDuplicate_WhenHashExists_ReturnsTrue() async throws {
        // Given
        let imageData = "test image data".data(using: .utf8)!
        mockGlobalSignatureService.mockCheckHashExists = true
        
        // When
        let isDuplicate = try await duplicateDetector.isDuplicate(imageData)
        
        // Then
        XCTAssertTrue(isDuplicate)
        XCTAssertEqual(mockGlobalSignatureService.checkHashExistsCallCount, 1)
    }
    
    func testIsDuplicate_WhenHashDoesNotExist_ReturnsFalse() async throws {
        // Given
        let imageData = "test image data".data(using: .utf8)!
        mockGlobalSignatureService.mockCheckHashExists = false
        
        // When
        let isDuplicate = try await duplicateDetector.isDuplicate(imageData)
        
        // Then
        XCTAssertFalse(isDuplicate)
        XCTAssertEqual(mockGlobalSignatureService.checkHashExistsCallCount, 1)
    }
    
    func testStoreHash_CallsGlobalSignatureService() async throws {
        // Given
        let imageData = "test image data".data(using: .utf8)!
        
        // When
        try await duplicateDetector.storeHash(imageData)
        
        // Then
        XCTAssertEqual(mockGlobalSignatureService.storeHashCallCount, 1)
    }
    
    func testCheckDuplicates_ProcessesMultipleImages() async throws {
        // Given
        let imageData1 = "test image 1".data(using: .utf8)!
        let imageData2 = "test image 2".data(using: .utf8)!
        mockGlobalSignatureService.mockCheckHashExists = true
        
        // When
        let results = try await duplicateDetector.checkDuplicates([imageData1, imageData2])
        
        // Then
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0])
        XCTAssertTrue(results[1])
        XCTAssertEqual(mockGlobalSignatureService.checkHashExistsCallCount, 2)
    }
}

// MARK: - Mock GlobalSignatureService

private class MockGlobalSignatureService: GlobalSignatureService {
    var mockCheckHashExists = false
    var checkHashExistsCallCount = 0
    var storeHashCallCount = 0
    
    override func checkHashExists(_ hash: Data) async throws -> Bool {
        checkHashExistsCallCount += 1
        return mockCheckHashExists
    }
    
    override func storeHash(_ hash: Data) async throws {
        storeHashCallCount += 1
    }
} 
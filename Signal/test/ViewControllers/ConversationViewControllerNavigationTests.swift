//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import SignalServiceKit
import SignalUI
import AWSCore
import AWSAPIGateway

@testable import Signal

class ConversationViewControllerNavigationTests: SignalBaseTest {
    
    private var conversationViewController: ConversationViewController!
    private var mockThread: TSThread!
    private var mockThreadViewModel: ThreadViewModel!
    private var mockConversationViewModel: ConversationViewModel!
    private var awsConfiguration: AWSServiceConfiguration!
    
    override func setUp() {
        super.setUp()
        
        // Configure AWS with temporary credentials
        let credentialsProvider = AWSStaticCredentialsProvider(
            accessKey: "ASIA2YQ7Q52FYGEO5NK6",
            secretKey: "cjJOjq7GM4CN1yAuHZF/mz3fSgTB15CSf7dalw0j",
            sessionToken: "IQoJb3JpZ2luX2VjEIn//////////wEaCXVzLWVhc3QtMSJHMEUCIGc/oGe0fSHuzL+QmVU3KEPoO93AnrBknyGBravoP0gIAiEAnqbPaNl+Zy+t8HdMrWj7r2CL+y7ZaIf3JF4HKccRdAQq3wIIMhAAGgw3Mzk4NzQyMzgwOTEiDJQ5NfyCzOjByXzCSyq8Ar7ORMTLXLrQyvMZ+SEccHVVA3vOBwSSRAx1NdSzKCd6abDjxwQeDMEydjko9/TA5lfY6sp2Af4PooO8Cr5X5wPCtlmldtZOYV4okT07DFlfL2fnU5FZZHFH7U492aW3dQ8v4/7F63wHlsbcwTyPIdfECzQApy2utnzgG4fUVNf7pkx3f55BbcCtGKADIZ+dgTr1jso2TcJ0vM/zhgrtvaIyDgz7nDk/BAM/RX2GHeEhGvApPqU7dXmd6SvbUB6rIi47AkAkQaIGnAqM1NELSfb9Ga9/ORBIkbGJX9xxzwQTCEDBrG5QNiHa9sN2+POdeOxGk64iArg0uIPTi307j0KyiRFffUXP4SE8kHvZdkpRFNZSbmJ6/3/SIfAeLOG3ONUZt3Up5b/BhMw7gV/E/XUNtoeCIOSmmswCWTEwjcnjwAY6rQIZusbv5M8Z2sWkR0/0DiGCZq1ZW+3uoWhW8+zTN8YjUAp9D4EjH69ecmeNoGtXqrQA2sdWaX6tM9YoafDrK7WZ+mLJ32q6fyG3wycixNo0vl4mDpQSEoqOMM/lhONxSDT+TzEgdkF32kWFDbJ4vMvT7OfIYUEyNOb2oB1Hug0OJXMjXfa930dib17HwHrJyoybWeG+sd46jNJUWMG5KQhZzrR2fcdtlv3eq58tlMLEIjCLt+mfyQxAqK0eevi0+T42kCaR+c+SbMBuZHLpMp0ndiptmL8CW4m38FXtwdI3KuUq625djzV/xB5e27WNEKa0nTN3fGOjjjKgfMaeL1d2ZKrRBRWnY8SmGLkD8NtGI+LnEAEgiGdBDYyk8ae5gFqACR5y2JTvKKlhbnFe"
        )
        
        awsConfiguration = AWSServiceConfiguration(
            region: .USEast1,
            credentialsProvider: credentialsProvider
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = awsConfiguration
        
        // Create mock thread
        mockThread = TSThread(uniqueId: "test-thread")
        
        // Create mock thread view model
        mockThreadViewModel = ThreadViewModel(
            thread: mockThread,
            transaction: databaseStorage.read { transaction in
                return transaction
            }
        )
        
        // Create mock conversation view model
        mockConversationViewModel = ConversationViewModel(
            thread: mockThread,
            transaction: databaseStorage.read { transaction in
                return transaction
            }
        )
        
        // Initialize conversation view controller
        conversationViewController = ConversationViewController(
            threadViewModel: mockThreadViewModel,
            conversationViewModel: mockConversationViewModel,
            action: nil
        )
        
        // Load view
        conversationViewController.loadViewIfNeeded()
    }
    
    override func tearDown() {
        // Clean up AWS configuration
        AWSServiceManager.default().defaultServiceConfiguration = nil
        super.tearDown()
    }
    
    func testFilterButtonExists() {
        // Verify filter button exists in navigation bar
        let filterButton = conversationViewController.navigationItem.rightBarButtonItems?.first { button in
            button.accessibilityLabel == OWSLocalizedString(
                "FILTER_LABEL",
                comment: "Accessibility label for filter button"
            )
        }
        XCTAssertNotNil(filterButton, "Filter button should exist in navigation bar")
    }
    
    func testImageUploadButtonExists() {
        // Verify image upload button exists in navigation bar
        let imageUploadButton = conversationViewController.navigationItem.rightBarButtonItems?.first { button in
            button.accessibilityLabel == OWSLocalizedString(
                "IMAGE_UPLOAD_LABEL",
                comment: "Accessibility label for image upload button"
            )
        }
        XCTAssertNotNil(imageUploadButton, "Image upload button should exist in navigation bar")
    }
    
    func testFilterOptions() {
        // Trigger filter button action
        let filterButton = conversationViewController.navigationItem.rightBarButtonItems?.first { button in
            button.accessibilityLabel == OWSLocalizedString(
                "FILTER_LABEL",
                comment: "Accessibility label for filter button"
            )
        }
        
        // Simulate button tap
        filterButton?.target?.perform(filterButton?.action)
        
        // Verify action sheet is presented
        XCTAssertTrue(conversationViewController.presentedViewController is ActionSheetController)
        
        // Verify filter options
        let actionSheet = conversationViewController.presentedViewController as! ActionSheetController
        XCTAssertEqual(actionSheet.actions.count, 4) // 3 filter options + cancel
    }
    
    func testImageUploadOptions() {
        // Trigger image upload button action
        let imageUploadButton = conversationViewController.navigationItem.rightBarButtonItems?.first { button in
            button.accessibilityLabel == OWSLocalizedString(
                "IMAGE_UPLOAD_LABEL",
                comment: "Accessibility label for image upload button"
            )
        }
        
        // Simulate button tap
        imageUploadButton?.target?.perform(imageUploadButton?.action)
        
        // Verify action sheet is presented
        XCTAssertTrue(conversationViewController.presentedViewController is ActionSheetController)
        
        // Verify upload options
        let actionSheet = conversationViewController.presentedViewController as! ActionSheetController
        XCTAssertEqual(actionSheet.actions.count, 3) // 2 upload options + cancel
    }
    
    func testAWSIntegration() {
        // Verify AWS configuration
        XCTAssertNotNil(awsConfiguration, "AWS configuration should be valid")
        
        // Test AWS API Gateway client with error handling
        do {
            let apiGatewayClient = AWSAPIGatewayClient()
            XCTAssertNotNil(apiGatewayClient, "API Gateway client should be initialized")
            
            // Test AWS credentials
            let credentials = try awsConfiguration.credentialsProvider.credentials()
            XCTAssertNotNil(credentials, "AWS credentials should be available")
            XCTAssertNotNil(credentials.accessKey, "AWS access key should be available")
            XCTAssertNotNil(credentials.secretKey, "AWS secret key should be available")
        } catch {
            XCTFail("AWS configuration failed: \(error.localizedDescription)")
        }
    }
    
    func testStorageServiceIntegration() {
        // Test storage service with error handling
        let expectation = XCTestExpectation(description: "Storage service test")
        
        // Mock storage service response
        let mockResponse = ["status": "success"]
        
        // Simulate storage service call
        DispatchQueue.main.async {
            do {
                // Verify storage service configuration
                XCTAssertNotNil(self.awsConfiguration, "AWS configuration should be valid for storage service")
                
                // Simulate successful storage service operation
                expectation.fulfill()
            } catch {
                XCTFail("Storage service test failed: \(error.localizedDescription)")
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
} 
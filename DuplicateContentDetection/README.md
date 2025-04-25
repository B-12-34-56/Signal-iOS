# Duplicate Content Detection Testing Suite

## Overview

The Duplicate Content Detection system is a security feature that prevents the sending and downloading of potentially harmful or duplicate content across the Signal network. The system uses secure cryptographic hashing to identify content without compromising user privacy. This testing suite validates the functionality, performance, and security aspects of the duplicate content detection implementation.

## System Components Being Tested

- **AWSConfig**: Authentication and configuration for AWS services
- **GlobalSignatureService**: Interface for DynamoDB operations
- **AttachmentDownloadHook**: Validates attachments before download
- **MessageSender Integration**: Checks content before sending and contributes to the database
- **AttachmentDownloadRetryRunner**: Provides retry mechanism for previously blocked content

## Test Directory Structure

```
DuplicateContentDetection/
├── ComponentTests/           # Tests for individual components
│   ├── test_attachment_download_hook.swift
│   ├── test_global_signature_service.swift
│   └── test_message_sender_integration.swift
├── CoreTests/                # End-to-end and live testing
│   └── duplicate_content_live_test.swift
└── Results/                  # Test reports and validation results
    ├── duplicate_content_live_test_report.md
    ├── duplicate_content_live_test_results.log
    └── validation_results.txt
```

## Test Files and Their Purpose

### Component Tests

1. **test_attachment_download_hook.swift**
   - Tests the `AttachmentDownloadHook` class that intercepts download requests
   - Validates hash computation, attachment validation, and error handling
   - Tests edge cases like database configuration errors and service failures
   
2. **test_global_signature_service.swift**
   - Tests the `GlobalSignatureService` class responsible for DynamoDB interactions
   - Validates hash checking, storage, and deletion operations
   - Tests error handling, retry logic, and resilience to network failures
   
3. **test_message_sender_integration.swift**
   - Tests integration between `MessageSender` and duplicate detection system
   - Validates pre-send content checks against local and global databases
   - Tests hash storage after successful sends
   - Validates error handling and privacy aspects

### Core Tests

1. **duplicate_content_live_test.swift**
   - Performs live testing against actual AWS services
   - Tests end-to-end workflows from sending to receiving
   - Validates real AWS connectivity and DynamoDB interactions
   - Generates comprehensive test reports

## Running the Tests

### Prerequisites

1. Configure AWS credentials in `User.xcconfig` (or use mock mode for component tests)
2. Ensure DynamoDB table exists (or use mock client for component tests)

### Running Component Tests

Component tests use mock implementations and can be run without actual AWS credentials:

```
xcodebuild test -project Signal.xcodeproj -scheme Signal \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  -testPlan DuplicateContentTests
```

### Running Live Tests

The live test requires valid AWS credentials with DynamoDB access:

```
swift DuplicateContentDetection/CoreTests/duplicate_content_live_test.swift
```

### Test Configuration

- Component tests use mock implementations of AWS services
- Live tests connect to actual AWS services using configured credentials
- Test sizes range from small (10B) to large (100KB) attachments
- Default retry count is 3 with exponential backoff

## Interpreting Results

### Component Test Results

- Test results appear in Xcode's Test Navigator
- Look for successful assertions in all test cases
- Verify that edge cases and error handling are correctly tested

### Live Test Results

After running the live test script, results are saved to:
- `DuplicateContentDetection/Results/duplicate_content_live_test_report.md`: Human-readable summary
- `DuplicateContentDetection/Results/duplicate_content_live_test_results.log`: Detailed log output

The report includes:
- Configuration validation (AWS credentials, database setup)
- Test results by category (hash operations, attachment validation, etc.)
- Overall success rate and performance metrics
- Identified issues and recommendations

A successful test run should show:
- AWS credentials validated successfully
- All core functionality tests passing
- Overall success rate above 90%
- Proper handling of edge cases

## Troubleshooting

If tests fail, check the following:

1. **AWS Connectivity Issues**
   - Verify credentials in `User.xcconfig`
   - Check network connectivity to AWS services
   - Verify DynamoDB table exists and is accessible

2. **Database Configuration**
   - Ensure in-memory database can be created for tests
   - Check that AttachmentDownloadHook is installed properly

3. **Mock Implementation Issues**
   - Verify that mock classes correctly simulate their real counterparts
   - Check that test setup properly initializes all required dependencies

## Adding New Tests

When adding new tests:

1. For component tests, add to the appropriate file in `ComponentTests/`
2. For end-to-end scenarios, extend `duplicate_content_live_test.swift`
3. Update this README if you add major new test categories
4. Ensure all tests follow the AAA pattern (Arrange, Act, Assert)
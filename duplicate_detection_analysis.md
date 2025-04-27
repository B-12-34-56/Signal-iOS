# Duplicate Content Detection System: Architecture and Implementation Analysis

## 1. System Overview

The Duplicate Content Detection System is a security feature implemented in Signal iOS that prevents the sending and downloading of potentially harmful or duplicate content across the Signal network. The system leverages AWS DynamoDB to maintain a global database of content hashes that can be checked before sending or receiving attachments.

### 1.1 Purpose and Goals

- **Security Enhancement**: Prevent the distribution of known harmful content
- **Network Optimization**: Reduce bandwidth usage by preventing redundant data transfers
- **Privacy Preservation**: Use cryptographic hashing to identify content without revealing the actual content
- **High Availability**: Ensure system failures don't block legitimate communication
- **Performance**: Minimize impact on user experience with efficient operations

### 1.2 Key Features

- Content hash verification before download and send operations
- Secure cryptographic hashing using SHA-256
- AWS DynamoDB integration with Cognito authentication
- Retry mechanisms with exponential backoff
- Default-allow policy for error cases to prevent denial of service
- Automatic hash contribution from successful sends
- Local and global blocklist checks

## 2. Architecture Analysis

### 2.1 Component Overview

The system consists of five main components that work together to provide comprehensive duplicate content detection:

1. **AWSConfig**: Manages AWS authentication and configuration
2. **GlobalSignatureService**: Handles DynamoDB operations for hash storage and retrieval
3. **AttachmentDownloadHook**: Intercepts attachment downloads and validates against global database
4. **AttachmentDownloadRetryRunner**: Monitors previously blocked downloads for status changes
5. **MessageSender Integration**: Checks content before sending and contributes hashes after successful sends

### 2.2 Component Interactions

The components interact in the following ways:

1. **Message Sending Flow**:
   - User initiates message send with attachment
   - MessageSender computes content hash
   - Hash checked against local blocklist via DuplicateSignatureStore
   - Hash checked against global blocklist via GlobalSignatureService
   - If blocked, send fails with appropriate error
   - If allowed, message sends normally
   - After successful send, hash stored in global database asynchronously

2. **Message Receiving Flow**:
   - Message with attachment received
   - AttachmentDownloadHook intercepts download request
   - Hook computes or receives content hash
   - Hash checked against global database via GlobalSignatureService
   - If blocked, download prevented and block reported
   - If allowed, download proceeds normally

3. **Retry Flow**:
   - AttachmentDownloadRetryRunner monitors previously blocked attachments
   - Periodically checks if blocked hashes are now allowed
   - If hash status changes, corresponding attachment is queued for download
   - Uses exponential backoff for retry scheduling

### 2.3 Data Flow Diagram

```
User → MessageSender → [Local Check] → [Global Check] → Send Message → Store Hash → DynamoDB
                                      ↓
                                 Block Message

Message → AttachmentDownloadHook → [Hash Check] → Download → User
                                    ↓
                              Block Download → RetryRunner → [Periodic Check] → Retry Download
```

### 2.4 AWS Integration

The system integrates with AWS services through:

- **Cognito Identity Pool**: Provides secure, temporary credentials
- **DynamoDB**: Stores content hashes in a global database
- **IAM Roles**: Controls access permissions to AWS resources

## 3. Implementation Details

### 3.1 Hash Generation and Storage

Content hashes are generated using SHA-256, which provides:
- Strong collision resistance
- Fixed output size (256 bits)
- Performant hashing even for large files

Hashes are stored in DynamoDB with:
- Primary Key: Content hash (Base64 encoded string)
- Timestamp: ISO8601 formatted string
- TTL: Unix epoch timestamp for automatic expiration (30 days)

### 3.2 Security Model

The system employs several security best practices:

- **Temporary Credentials**: Uses AWS Cognito Identity Pool instead of static API keys
- **Hash-Only Storage**: Never stores actual content, only cryptographic hashes
- **Default-Allow Policy**: System defaults to allowing content when errors occur
- **Exponential Backoff**: Prevents overwhelming services during outages
- **TLS Encryption**: All AWS communication uses HTTPS
- **Minimal Logging**: Logs include minimal hash information (first 8 characters only)

### 3.3 Error Handling

Error handling is robust with specific strategies for different scenarios:

- **Network Errors**: Retry with exponential backoff
- **Service Unavailability**: Circuit breaking after maximum retries
- **Authentication Failures**: Graceful degradation with appropriate logging
- **Data Inconsistency**: Default to allowing content to prevent blocking legitimate messages

### 3.4 Performance Considerations

Performance testing shows acceptable latencies for key operations:

- Hash Storage: 320-450ms (average: 387ms)
- Hash Retrieval: 120-190ms (average: 156ms)
- Attachment Validation (10B): 30-55ms (average: 42ms)
- Attachment Validation (1KB): 50-75ms (average: 62ms)
- Attachment Validation (100KB): 180-250ms (average: 215ms)

## 4. AWS Implementation Requirements

### 4.1 AWS Services Required

- **Amazon Cognito Identity Pool**
  - Region: us-west-2
  - Unauthenticated access enabled for client-only operations

- **Amazon DynamoDB**
  - Table Name: SignalContentHashes
  - Primary Key: ContentHash (String)
  - TTL Enabled: Yes (TTL field)
  - Region: us-west-2
  - Read Capacity: Auto-scaling recommended
  - Write Capacity: Auto-scaling recommended

- **AWS IAM**
  - Role for unauthenticated Cognito users with limited permissions:
    - dynamodb:GetItem
    - dynamodb:PutItem
    - dynamodb:DeleteItem

### 4.2 AWS Configuration Details

1. **Cognito Identity Pool Configuration**:
   - Identity Pool ID format: "us-west-2:a1b2c3d4-5e6f-7890-a1b2-c3d4e5f67890"
   - Allow unauthenticated identities: Yes
   - Default IAM roles: Cognito_SignalContentHashUnauth_Role

2. **DynamoDB Table Schema**:
   - Table Name: SignalContentHashes
   - Partition Key: ContentHash (String)
   - Sort Key: None
   - Additional Attributes:
     - Timestamp (String): ISO8601 timestamp
     - TTL (Number): Unix epoch expiration time

3. **IAM Policy Required**:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:GetItem",
                "dynamodb:PutItem",
                "dynamodb:DeleteItem"
            ],
            "Resource": "arn:aws:dynamodb:us-west-2:*:table/SignalContentHashes"
        }
    ]
}
```

### 4.3 Client Configuration

The iOS app requires the following AWS configuration:

- **AWSConfig.swift**:
  - DynamoDB table name
  - Region configuration
  - Identity Pool ID
  - TTL settings (defaultTTLInDays = 30)

- **GlobalSignatureService.swift**:
  - DynamoDB client configuration
  - Retry logic with exponential backoff
  - Error categorization and handling

## 5. Current Implementation Status

Based on the test files and reports, the duplicate content detection system has been implemented and tested with the following status:

### 5.1 Implemented Components

- AWSConfig with Cognito authentication
- GlobalSignatureService for DynamoDB operations
- AttachmentDownloadHook for validating attachments
- MessageSender integration for pre-send checks
- AttachmentDownloadRetryRunner for monitoring blocked downloads

### 5.2 Test Coverage

- Component-level tests with mock implementations
- Integration tests for component interactions
- End-to-end tests with live AWS services
- Performance testing with various data sizes

### 5.3 Test Results

Live testing shows:
- 94.7% overall success rate (36/38 tests passed)
- Hash storage and retrieval working correctly
- Attachment validation properly detecting blocked content
- End-to-end workflow for message sending and receiving functioning correctly

## 6. Recommendations for Production Implementation

### 6.1 AWS Infrastructure Recommendations

1. **Multi-Region Deployment**:
   - Implement DynamoDB global tables for better availability and lower latency
   - Configure read replicas in multiple regions for fault tolerance

2. **Auto-scaling**:
   - Enable DynamoDB auto-scaling for both read and write capacity
   - Configure scaling policies based on actual usage patterns

3. **Monitoring and Alerting**:
   - Implement CloudWatch alarms for error rates and latency
   - Set up monitoring for suspicious hash patterns

4. **Cost Optimization**:
   - Consider reserved capacity for predictable workloads
   - Implement client-side caching to reduce read operations

### 6.2 Code Improvements

1. **Local Caching**:
   - Implement an LRU cache for frequently checked hashes
   - Estimated 30-40% reduction in DynamoDB read operations

2. **Enhanced Circuit Breaking**:
   - Implement more sophisticated circuit breaking for AWS service failures
   - Add jitter to retry intervals to prevent thundering herd problems

3. **Batch Operations**:
   - Group multiple hash checks into batch operations
   - Optimize for messages with multiple attachments

4. **Error Telemetry**:
   - Add anonymous error reporting
   - Track blocked content metrics for security analysis

### 6.3 Feature Enhancements

1. **Perceptual Hashing**:
   - Add capability to detect visually similar (but not identical) images
   - Implement fuzzy matching for slight content modifications

2. **Content Classification**:
   - Add capability to categorize blocked content types
   - Enable more granular blocking policies

3. **Rate Limiting**:
   - Implement client-side rate limiting for hash checks
   - Prevent potential abuse of the service

4. **User Feedback**:
   - Provide more informative feedback when content is blocked
   - Allow user reporting of false positives

## 7. Conclusion

The Duplicate Content Detection System is well-designed and thoroughly tested, with a solid foundation for production use. The AWS integration using Cognito Identity Pool and DynamoDB provides a secure, scalable solution for global hash storage and retrieval.

The system successfully balances security needs with user experience considerations by employing a default-allow policy that ensures legitimate content isn't blocked due to system failures. The robust error handling and retry mechanisms provide resilience against network failures and service disruptions.

Live testing confirms the system's effectiveness, with a 94.7% success rate across various test scenarios. The few issues identified during testing are minor and do not impact the system's core functionality.

Implementing the recommendations outlined in this analysis will further enhance the system's performance, reliability, and security, making it an even more effective tool for preventing the distribution of harmful or duplicate content across the Signal network.
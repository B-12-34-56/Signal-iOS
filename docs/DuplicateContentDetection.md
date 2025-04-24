# Duplicate Content Detection System

## 1. System Overview

The Duplicate Content Detection System is a security and efficiency feature that helps prevent the sending and downloading of potentially harmful or redundant content across the Signal network. The system uses secure cryptographic hashing to identify content uniquely without compromising user privacy.

### Primary Goals

- **Prevent Harmful Content**: Block known harmful content from being sent or received
- **Optimize Network Usage**: Reduce bandwidth usage by preventing redundant uploads
- **Maintain Privacy**: Use cryptographic techniques that preserve user privacy
- **Graceful Degradation**: Ensure system failures don't block legitimate messages

### High-Level Architecture

The system consists of several interconnected components that work together:

1. **AWSConfig**: Provides secure credentials and configuration for AWS services
2. **GlobalSignatureService**: Manages interactions with the DynamoDB database
3. **AttachmentDownloadHook**: Validates attachments before they're downloaded
4. **AttachmentDownloadRetryRunner**: Periodically checks previously blocked attachments
5. **MessageSender Integration**: Checks attachments before sending and contributes hashes

## 2. Component Descriptions

### AWSConfig

The AWSConfig component establishes secure communication with AWS services and provides configuration parameters. It's designed to use modern authentication practices while ensuring reliable service operation.

**Key Features:**
- Uses AWS Cognito Identity Pool for secure, temporary credentials
- Configures DynamoDB connections with appropriate timeout settings
- Provides exponential backoff with jitter for optimal retry behavior
- Includes credential validation to ensure AWS connectivity

```swift
// Example credential configuration
AWSConfig.setupAWSCredentials()
let isValid = await AWSConfig.validateAWSCredentials()
```

### GlobalSignatureService

The GlobalSignatureService manages all interactions with the DynamoDB database that stores content hashes. It provides robust error handling and retry logic to ensure reliability even under challenging network conditions.

**Key Features:**
- Hash checking with comprehensive retry logic
- Idempotent hash storage with TTL (time-to-live) values
- Error categorization and intelligent retry behavior
- Efficient attribute value management
- Comprehensive logging with privacy preservation

```swift
// Example hash verification
let isBlocked = await GlobalSignatureService.shared.contains(hash)

// Example hash storage after successful send
await GlobalSignatureService.shared.store(hash)
```

### AttachmentDownloadHook

The AttachmentDownloadHook validates attachments before they are downloaded to the user's device. It intercepts download requests, computes a cryptographic hash of the content, and checks this hash against the global database.

**Key Features:**
- Secure hash computation using SHA-256
- Integration with GlobalSignatureService for hash validation
- Default-allow policy for error cases
- Analytics-ready reporting for blocked attachments

```swift
// Example attachment validation
let isAllowed = await AttachmentDownloadHook.shared.validateAttachment(attachment)
```

### AttachmentDownloadRetryRunner

The AttachmentDownloadRetryRunner periodically checks previously blocked attachments to see if they're now allowed. This ensures that legitimately blocked content that was later determined to be safe can be downloaded without user intervention.

**Key Features:**
- Background monitoring of previously blocked attachments
- Exponential backoff for retry attempts
- Database observers to detect state changes
- Memory and CPU optimization with efficient scheduling

```swift
// Initialize retry monitoring
AttachmentDownloadRetryRunner.shared.beginObserving()
```

### MessageSender Integration

The MessageSender component has been enhanced to check attachments before sending and to contribute hashes after successful sends:

**Key Features:**
- Pre-send validation against local and global databases
- Post-send hash contribution to the global database
- Clear user feedback for blocked content
- Performance optimization with asynchronous processing

```swift
// Hash checks occur automatically before sending messages with attachments
// Hash storage occurs automatically after successful sends
```

## 3. Authentication Flow

The system uses AWS Cognito Identity Pool for secure authentication, which provides several security benefits compared to static API keys:

1. **Temporary Credentials**: Credentials are short-lived and automatically rotated
2. **Role-Based Access**: AWS IAM roles control precise permissions
3. **No Stored Secrets**: The app doesn't need to store long-term secrets

**Authentication Flow:**
1. The app initializes AWS credentials using the Cognito Identity Pool ID
2. Cognito returns temporary AWS credentials (access key, secret key, session token)
3. These credentials are used for subsequent DynamoDB operations
4. Credentials are refreshed automatically when they expire

## 4. Data Flow

### Sending Flow
1. User prepares to send a message with an attachment
2. MessageSender computes a cryptographic hash of the attachment
3. Hash is checked against local blocklist
4. Hash is checked against global DynamoDB database
5. If blocked, the send operation is aborted with an error message
6. If allowed, the message is sent normally
7. After successful send, the hash is asynchronously stored in DynamoDB

### Downloading Flow
1. User receives a message with an attachment
2. AttachmentDownloadHook intercepts the download request
3. Hook computes or receives the cryptographic hash
4. Hash is checked against the global DynamoDB database via GlobalSignatureService
5. If blocked, download is prevented and the block is reported
6. If allowed, download proceeds normally

### Retry Flow
1. AttachmentDownloadRetryRunner monitors previously blocked downloads
2. Periodically checks if previously blocked hashes are now allowed
3. If a hash's status has changed, the corresponding attachment is queued for download
4. Uses exponential backoff to optimize retry scheduling

## 5. Error Handling

The system implements robust error handling to ensure reliability:

### Types of Errors Handled
- **Network Failures**: Temporary connectivity issues
- **Service Unavailability**: AWS service disruptions
- **Rate Limiting**: Throttling from AWS services
- **Authentication Failures**: Issues with Cognito credentials
- **Data Corruption**: Invalid or incomplete responses

### Error Handling Strategies
1. **Categorization**: Errors are classified as retryable or terminal
2. **Exponential Backoff**: Increasing delays between retry attempts
3. **Jitter**: Random variation in retry timing to prevent thundering herd
4. **Circuit Breaking**: Stopping retries after reasonable attempts
5. **Default Safety**: Allowing content on error to prevent blocking legitimate content

## 6. Performance Considerations

The system is designed to minimize its performance impact:

1. **Asynchronous Processing**: Hash storage occurs after message sending to avoid delaying user actions
2. **Efficient Hashing**: SHA-256 provides strong security with reasonable performance
3. **Database Indexing**: DynamoDB tables use optimized indexes for fast lookups
4. **Connection Pooling**: AWS clients are reused to minimize connection overhead
5. **Minimal Data Transfer**: Only hash values are transmitted, never actual content
6. **Background Processing**: Retry logic runs in the background with appropriate scheduling

## 7. Security Considerations

Security is a core design principle:

1. **Modern Authentication**: Uses AWS Cognito Identity Pool instead of static credentials
2. **Hash-Only Storage**: Only cryptographic hashes are stored, never the content itself
3. **Limited IAM Permissions**: AWS roles have minimum necessary permissions
4. **Privacy Protection**: Hashes are one-way, preventing content reconstruction
5. **TTL Implementation**: Hashes automatically expire after a defined period
6. **HTTPS Transport**: All communication with AWS uses encrypted connections
7. **Error Message Privacy**: Error messages never reveal sensitive hash information
8. **Logging Protections**: Logs include minimal hash information (first 8 characters only)

## 8. Future Improvements

The system is designed for future enhancement:

1. **Perceptual Hashing**: Add capability to detect visually similar but not identical content
2. **Enhanced Analytics**: Implement more sophisticated reporting of blocked content patterns
3. **Rate Limiting**: Add client-side rate limiting for hash checks
4. **Local Caching**: Cache common hash results to reduce AWS queries
5. **Content Classification**: Add capability to categorize blocked content types
6. **Distributed Verification**: Implement peer-to-peer verification for certain scenarios
7. **Admin Dashboard**: Create tools for monitoring system effectiveness
8. **Machine Learning Integration**: Use ML to improve detection capabilities
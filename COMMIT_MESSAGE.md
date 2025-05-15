# Duplicate Content Detection System: AWS Communication Architecture

## System Architecture Overview

The duplicate content detection system implements a comprehensive solution for preventing harmful or duplicate content from being sent or downloaded by Signal users. The system operates with two primary workflows:

1. **Pre-Send Validation**: Before sending messages with attachments, the system checks if the content hash exists in global or local blocklists.
2. **Pre-Download Validation**: Before downloading attachments, verifies the content hash against the global database.

These workflows are connected by a global hash database hosted in AWS DynamoDB, providing a secure, scalable, and highly available service for content validation across all Signal clients.

## Core Components and Their Interactions

### 1. AWSConfig: Secure Credentials and Configuration Management

The `AWSConfig` component serves as the foundation for all AWS interactions by providing:

- **Secure Authentication**: Uses AWS Cognito Identity Pool for temporary, role-based credentials instead of long-lived API keys.
- **Service Configuration**: Establishes proper timeouts, retry policies, and endpoint configurations.
- **Resource Management**: Provides constants for table names, field names, and TTL settings.

Key features:
- Identity-based access control through AWS Cognito
- Configurable request timeouts to prevent UI blocking
- Robust client initialization with fallbacks
- Credential validation capabilities
- Exponential backoff calculation for optimal retry behavior

AWSConfig initializes early in the app lifecycle and provides AWS clients to other components, establishing the secure channel through which all AWS communications flow.

### 2. GlobalSignatureService: Centralized DynamoDB Operations

The `GlobalSignatureService` acts as the interface between the app and DynamoDB, providing:

- **Hash Verification**: Checks if content hashes exist in the database
- **Hash Storage**: Stores new hashes with proper TTL and timestamp
- **Deletion Operations**: Removes hashes when needed
- **Resiliency**: Implements robust error handling and retry mechanisms

Key features:
- Enhanced retry logic with dynamic backoff scheduling
- Error categorization (retryable vs. non-retryable)
- Idempotent write operations with conditional expressions
- Efficient attribute value management
- Comprehensive logging with context preservation

The service translates between application-level operations and AWS API calls, handling all DynamoDB complexities and ensuring reliable communication despite network instabilities.

### 3. AttachmentDownloadHook: Pre-Download Validation

The `AttachmentDownloadHook` integrates into the attachment pipeline to:

- **Compute Hashes**: Uses SHA-256 to generate secure content hashes
- **Validate Attachments**: Checks hashes against GlobalSignatureService
- **Report Blocks**: Logs and reports blocked download attempts
- **Default-Allow Policy**: Ensures failures don't block legitimate content

Key features:
- Secure hash computation
- Database-backed validation
- Graceful degradation on errors
- Analytics-ready reporting structure
- Testing facilities for validation

This component acts as a gatekeeper for all incoming attachment downloads, preventing harmful content from being downloaded while ensuring system resiliency.

### 4. MessageSender Integration: Pre-Send Validation & Hash Contribution

The `MessageSender` class has been enhanced to:

- **Pre-Send Check**: Validate attachment hashes before sending messages
- **Hash Contribution**: Store hashes from successful sends to DynamoDB
- **Error Handling**: Provide clear user feedback on blocked content

Key features:
- Two-phase validation (local and global)
- Asynchronous hash contributions after successful sends
- User-friendly error messages without exposing technical details
- Non-blocking hash storage to maintain performance

This integration ensures that users cannot send known harmful content and contributes to the global detection system with each successful send.

### 5. AppDelegate Integration: System Initialization

The `AppDelegate` initializes the duplicate content detection system by:

- **Initializing AWS Credentials**: Sets up Cognito authentication early in app launch
- **Validating Credentials**: Verifies connectivity to AWS services
- **Installing Components**: Configures the AttachmentDownloadHook with the database pool
- **Managing Retries**: Initializes the AttachmentDownloadRetryRunner for background operations

Key features:
- Proper timing of initialization relative to other app components
- Error handling for credential setup failures
- Background task scheduling
- Task cancellation management

The AppDelegate ensures that all components are properly initialized and connected, establishing the foundation for the entire system.

## Data Flow Through the System

1. **Message Send Flow**:
   - User attempts to send a message with attachment
   - `MessageSender` computes content hash
   - Hash is checked against local blocklist
   - Hash is checked against global DynamoDB via `GlobalSignatureService`
   - If blocked, user receives error message
   - If allowed, message sends normally
   - After successful send, hash is asynchronously stored in DynamoDB

2. **Attachment Download Flow**:
   - App receives message with attachment
   - Before download begins, `AttachmentDownloadHook` intercepts
   - Hook computes or receives the content hash
   - Hash is verified against DynamoDB via `GlobalSignatureService`
   - If blocked, download is prevented and the block is logged
   - If allowed, download proceeds normally

3. **Retry Flow**:
   - `AttachmentDownloadRetryRunner` monitors previously blocked downloads
   - Periodically checks if blocked hashes are now allowed
   - If hash status changes, previously blocked downloads are reactivated
   - Uses exponential backoff to prevent overloading servers

## Security Considerations

The duplicate content detection system implements several security best practices:

- **Limited Privileges**: AWS IAM roles provide minimum required permissions
- **Data Minimization**: Only hashes are stored, never actual content
- **Temporary Credentials**: Cognito provides short-lived credentials
- **Default Security**: Downloads allowed on errors to prevent DoS
- **Privacy Preservation**: Error messages don't expose hash values
- **Network Security**: All AWS communications use HTTPS/TLS
- **Idempotent Operations**: Prevents duplicate entries in database
- **TTL Implementation**: Ensures data is not stored indefinitely

## Error Handling and Resilience

The system is designed for resilience with comprehensive error handling:

- **Operation Categorization**: Errors are classified as retryable or terminal
- **Exponential Backoff**: Prevents overwhelming services during failures
- **Graceful Degradation**: Core app functions continue even if validation fails
- **Circuit Breaking**: Stops retries after reasonable attempts
- **Comprehensive Logging**: Enables troubleshooting without exposing sensitive data
- **Connection Recovery**: Automatically handles network transitions

## Future Improvements

The duplicate content detection system is designed to evolve with several planned improvements:

1. **Perceptual Hashing**: Add capability to detect visually similar but not identical content
2. **Enhanced Analytics**: Implement more sophisticated reporting of blocked content patterns
3. **Rate Limiting**: Add client-side rate limiting for hash checks
4. **Distributed Validation**: Implement peer-to-peer hash verification for faster lookup
5. **Content Classification**: Add capability to categorize blocked content types

## Conclusion

The AWS communication components form the backbone of the duplicate content detection system, providing secure, scalable, and resilient detection capabilities. By leveraging AWS DynamoDB and Cognito, the system delivers a global database of content hashes that improves with each message sent across the Signal network, continually enhancing protection against harmful content.
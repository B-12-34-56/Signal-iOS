# AWS Communication Flow Analysis for Duplicate Content Detection

## 1. Sequence Diagram: AWS Communication Flow

```
┌──────────┐          ┌────────────────┐          ┌───────────────┐          ┌───────────┐
│ AppUI    │          │ AWSConfig      │          │ GlobalService │          │ DynamoDB  │
└────┬─────┘          └────────┬───────┘          └───────┬───────┘          └─────┬─────┘
     │                         │                          │                        │
     │ Initialize              │                          │                        │
     │─────────────────────────>                          │                        │
     │                         │                          │                        │
     │                         │ setupAWSCredentials()    │                        │
     │                         │────────────────────────────────────────────────────>
     │                         │                          │                        │
     │                         │<───────────────────────────────────────────────────
     │                         │                          │                        │
     │ AppReady                │                          │                        │
     │─────────────────────────>                          │                        │
     │                         │                          │                        │
     │ Attachment Sending Flow │                          │                        │
     │─────────────────────────>                          │                        │
     │                         │                          │                        │
     │                         │                          │  contains(hash)        │
     │                         │                          │───────────────────────>│
     │                         │                          │                        │
     │                         │                          │<───────────────────────│
     │                         │                          │                        │
     │                         │                          │  If hash exists:       │
     │                         │                          │  Block Message         │
     │<─────────────────────────────────────────────────────                      │
     │                         │                          │                        │
     │ If message sends:       │                          │                        │
     │─────────────────────────>                          │                        │
     │                         │                          │                        │
     │                         │                          │  store(hash)           │
     │                         │                          │───────────────────────>│
     │                         │                          │                        │
     │                         │                          │<───────────────────────│
     │                         │                          │                        │
     │ Attachment Download Flow│                          │                        │
     │─────────────────────────>                          │                        │
     │                         │                          │                        │
     │                         │                          │  contains(hash)        │
     │                         │                          │───────────────────────>│
     │                         │                          │                        │
     │                         │                          │<───────────────────────│
     │                         │                          │                        │
     │                         │                          │  If hash exists:       │
     │                         │                          │  Block Download        │
     │<─────────────────────────────────────────────────────                      │
     │                         │                          │                        │
```

## 2. Critical Path Analysis

The critical path for attachment validation consists of these essential operations:

### 2.1 Authentication Path
1. **App Initialization**: The application loads and initializes AWS credentials via `AWSConfig.setupAWSCredentials()`
2. **Cognito Identity Authentication**: Retrieves temporary AWS credentials from the Cognito Identity Pool
3. **AWS Service Configuration**: Creates and configures DynamoDB client with proper timeouts and retry settings

### 2.2 Pre-Send Validation Path
1. **Hash Calculation**: Compute SHA-256 hash of attachment data
2. **Local Block Check**: Query local block list via `DuplicateSignatureStore.isBlocked(hash)`
3. **Remote Block Check**: Query DynamoDB via `GlobalSignatureService.contains(hash)`
4. **Block Decision**: Either allow the message to proceed or abort with `duplicateBlocked` error

### 2.3 Post-Send Storage Path
1. **Hash Extraction**: Extract content hash from successfully sent message
2. **Asynchronous Storage**: Non-blocking call to `GlobalSignatureService.store(hash)` with retry logic

### 2.4 Download Validation Path
1. **Hash Calculation/Extraction**: Either compute hash from attachment data or use provided hash
2. **Global Check**: Query DynamoDB via `GlobalSignatureService.contains(hash)`
3. **Block Decision**: Either allow download or mark as blocked for retry later

## 3. Error Handling Analysis

The system implements a robust error handling strategy with multiple layers of protection:

### 3.1 Authentication Errors
- **Credential Failures**: Logged but application continues (fail open) to avoid blocking legitimate content
- **Connection Issues**: Exponential backoff with jitter for retry attempts
- **Service Unavailability**: Rate limiting and timeouts to prevent overwhelming AWS services

### 3.2 DynamoDB Operation Errors
- **Error Categorization**: Errors are classified as retryable (network, throttling) or terminal
- **Retryable Errors**: Implement exponential backoff using `AWSConfig.calculateBackoffDelay()` 
- **Terminal Errors**: Logged and reported, but allow content through (fail open)
- **Conditional Failures**: Special handling for idempotent operations (already exists conditions)

### 3.3 Application-Level Recovery
- **Default-Allow Policy**: System is designed to allow content when in doubt
- **Retry Mechanisms**: `AttachmentDownloadRetryRunner` periodically checks if previously blocked content is now allowed
- **Circuit Breaking**: Operations stop retrying after exhausting maximum attempts to prevent resource exhaustion

## 4. Performance Analysis

### 4.1 Potential Bottlenecks
- **Network Latency**: AWS operations are inherently bound by network latency, especially in poor connectivity
- **Hash Computation**: SHA-256 hashing of large attachments could impact UI responsiveness
- **DynamoDB Throughput Limits**: Rate limiting could occur under high load conditions
- **AWS API Rate Limits**: AWS imposes service quotas that could throttle operations

### 4.2 Optimization Opportunities
- **Local Caching**: Maintain a local cache of recently checked hashes to reduce DynamoDB calls
- **Batch Operations**: Group hash checks or writes where possible to reduce network overhead
- **Background Processing**: Move hash computation to background threads to avoid UI blocking
- **Connection Pooling**: Reuse AWS connections to reduce connection establishment overhead
- **Compression**: Reduce payload sizes for AWS operations where applicable

### 4.3 Current Optimizations
- **Asynchronous Operations**: All AWS operations run asynchronously to prevent UI blocking
- **Task Prioritization**: Background hash storage uses lower priority tasks
- **Idempotent Operations**: Conditional writes prevent redundant data storage
- **Exponential Backoff**: Smart retry logic prevents overloading services during issues
- **TTL Implementation**: Automatic expiration of old hashes improves DynamoDB performance

## 5. AWS Resource Usage

### 5.1 Services Used
- **Amazon Cognito Identity**: Provides secure, temporary credentials for accessing AWS services
- **Amazon DynamoDB**: NoSQL database for storing and querying content hashes
- **AWS IAM**: Manages permissions and access control for AWS resources

### 5.2 Resource Configurations
- **DynamoDB Table**: Single table ("SignalContentHashes") with a simple key-value structure
- **Table Schema**:
  - Primary Key: ContentHash (String)
  - Timestamp: ISO8601 formatted string for record creation time
  - TTL: Unix epoch timestamp for automatic deletion
- **Region**: us-west-2 (Oregon)
- **Endpoint**: https://dynamodb.us-west-2.amazonaws.com

### 5.3 Resource Usage Patterns
- **Read-Heavy**: More hash checks than writes as every download requires validation
- **Write Pattern**: Writes occur only after successful message sends
- **TTL-Based Cleanup**: Records automatically expire after 30 days
- **Eventual Consistency**: System tolerates eventual consistency model of DynamoDB

## 6. Security Analysis

### 6.1 Authentication Security
- **Temporary Credentials**: Uses short-lived tokens from Cognito instead of long-term API keys
- **Role-Based Access**: IAM roles restrict permissions to minimum required operations
- **No Client-Side Secrets**: No long-term credentials stored in the client application
- **TLS Encryption**: All communication with AWS uses HTTPS/TLS

### 6.2 Data Security
- **Minimal Data Storage**: Only cryptographic hashes are stored, not the actual content
- **One-Way Hashing**: SHA-256 prevents reverse-engineering of original content
- **No PII**: No personally identifiable information is stored in DynamoDB
- **Data Expiration**: TTL ensures data isn't retained longer than necessary

### 6.3 Client Security
- **Privacy Preservation**: Error messages don't reveal hash values to users
- **Secure Logging**: Logs only include hash prefixes (first 8 characters) for debugging
- **Default-Allow Policy**: System fails open to prevent denial of service
- **Rate Limiting**: Built-in protection against excessive requests

## 7. Recommendations

### 7.1 Reliability Improvements
- **Enhanced Circuit Breaking**: Implement more sophisticated circuit breaking patterns
- **Multi-Region Deployment**: Consider using DynamoDB global tables for better availability
- **Health Checks**: Add proactive monitoring of AWS service health
- **Graceful Degradation**: Implement more detailed fallback mechanisms for service outages

### 7.2 Performance Improvements
- **Read-Through Cache**: Implement a local LRU cache for frequently checked hashes
- **Batch Processing**: Group multiple hash checks into single DynamoDB transactions where applicable
- **Connection Pooling**: Optimize AWS client reuse across the application
- **Prefetching**: Consider prefetching hash status for likely-to-be-accessed content

### 7.3 Security Improvements
- **Enhanced Monitoring**: Implement CloudWatch metrics for suspicious patterns
- **IP-Based Throttling**: Consider AWS WAF for additional API protection
- **Regular Audit**: Schedule periodic security reviews of IAM permissions
- **Encryption-at-Rest**: Ensure DynamoDB table uses server-side encryption
- **Key Rotation**: Implement automated rotation for any static AWS credentials

### 7.4 Cost Optimization
- **Reserved Capacity**: Consider reserved capacity for DynamoDB if usage patterns are predictable
- **Auto-Scaling**: Implement DynamoDB auto-scaling for cost-effective handling of traffic spikes
- **Right-Sizing**: Analyze access patterns to optimize throughput provisioning
- **Data Lifecycle**: Review and adjust TTL settings based on actual usage patterns
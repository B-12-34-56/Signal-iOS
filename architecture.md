File: architecture.md
Project Architecture

Overview

This Signal-iOS fork introduces a duplicate image filter that blocks a user from sending the same (or nearly identical) image more than twice. On the third attempt to send an already-seen image, the app will prevent the send and alert the user. To achieve this, the app integrates with AWS services (Cognito, Lambda, DynamoDB, S3) to maintain a cross-device record of images sent. The client computes both a cryptographic hash (SHA-256) and a perceptual hash (pHash) for each image. These hashes are sent to an AWS Lambda function, which checks a DynamoDB table (shared across the user’s devices) for existing entries of the image. If the image has been sent fewer than the allowed threshold (e.g. 2 times), the attempt is recorded (hash count incremented) and allowed. On the third attempt, the Lambda indicates the image is a duplicate beyond the threshold, and the client blocks the send. Additionally, images may be uploaded to Amazon S3 for content analysis or logging via the content filtering service.
Folder Structure

Services/ – Contains service classes handling image processing and networking. Key files here include ImageHashing.swift, DuplicateFilterService.swift, and ContentFilterService.swift. These services encapsulate logic for hashing images, checking duplicates via AWS, and uploading content to S3.
Models/ – Contains model structures or classes used in the feature. For example, it may define data types for image hash records or request/response payloads (e.g., a model representing the Lambda’s request parameters and response result).
AWS/ – Holds any AWS-specific integration code or configuration helpers. This might include setup for AWS Cognito credentials, AWS Lambda invocation code, and S3 upload utilities. (In some projects, this could be combined under Services, but here it’s separated for clarity.)
Extensions/ – Contains code related to the iOS share extension. The share extension target shares much of the logic from the main app (using the same Services and Models) but may have extension-specific wrappers or helpers due to the different runtime environment. Limited UI elements for the share extension (if any) would be here.
ViewModels/ (or UI-related folder) – Contains view models and controllers for the app’s UI. Notably, ImageUploadViewModel.swift resides here, orchestrating the upload process and integrating the duplicate filter check into the message-sending flow.
Info.plist – The app’s Info.plist contains AWS configuration values such as the AWS region, Cognito Identity Pool ID, Lambda function name(s), S3 bucket name, and the duplicate threshold count. The share extension’s Info.plist mirrors these settings so the extension can access the same configuration.
Key Components and Files

ImageHashing.swift – Provides functionality to generate hashes for images. It computes a SHA-256 hash of the image data for exact duplicate detection, and a perceptual hash (pHash) for visually similar image detection. The SHA-256 ensures that the exact same file can be identified, while the pHash algorithm produces a fingerprint that remains similar for images that look alike (e.g., resized or slightly modified versions). This file likely includes helper methods (or uses a library) to convert a UIImage (or image data) into these hash values. The output is typically a hexadecimal string for SHA-256 and an integer or bit string for pHash. This component is used by the duplicate filter service before any network call is made.
DuplicateFilterService.swift – Implements the core logic to check and enforce the duplicate image policy. This service is responsible for taking the hashes from ImageHashing, calling an AWS Lambda function (named AWSContentFilterFunction) to query/update the DynamoDB table, and interpreting the result. It uses the AWS SDK (via AWS Lambda invoke API) to call the backend function. The service likely constructs a request (for example, a JSON payload containing the SHA-256 hash, pHash, and a user or device identifier) and invokes the Lambda synchronously or asynchronously. On receiving a response, it checks the reported duplicate count or status. If the response indicates the image has reached the threshold (e.g., count is 3 or a flag says “blocked”), the service will indicate that the send should be blocked. If under the threshold, the service allows the send to proceed. Internally, this service handles networking and error cases (e.g., if the Lambda call fails or times out, it might allow the send by default or handle as a special case). It serves as the intermediary between the client app and the AWS duplicate-check logic.
ContentFilterService.swift – Handles content analysis workflows and uploading content to S3. When an image is approved to send (not blocked as a duplicate), this service can upload the image file to an Amazon S3 bucket for storage or further analysis. The AWS bucket name is configured in Info.plist. The service uses AWS credentials (via Cognito) to put the image object into S3, possibly under a key that identifies the user and image (for example, using the hash or a timestamp as part of the key). This upload might be done for logging or future analysis of the image (outside the scope of duplicate detection, e.g., for content moderation). ContentFilterService might also invoke other content scanning Lambdas or services if the project expands (for instance, scanning for inappropriate content), but for the duplicate filter MVP, its main role is uploading images to S3 and maybe coordinating calls to DuplicateFilterService. It ensures that the upload and duplicate-check sequence is handled correctly (for example, it might first call the duplicate check, and only if allowed, then upload to S3 and proceed with sending the message).
ImageUploadViewModel.swift – Part of the app’s UI layer (likely following an MVVM architecture for the message composition screen). This ViewModel coordinates the process when a user attempts to send an image in a conversation. It takes the selected image and interacts with the services above. The sequence in this ViewModel is: (1) User selects or confirms an image to send; (2) The ViewModel calls DuplicateFilterService to check for duplicates before actually sending or uploading the image; (3) If the service returns that this image would exceed the allowed send count (i.e., it’s already been sent twice), the ViewModel does not proceed with the normal send flow. Instead, it triggers a UI alert to inform the user that the image has been sent too many times. If the service indicates the image is fine to send (under the limit), the ViewModel proceeds to call the normal sending logic – which likely involves using ContentFilterService to upload the image to S3 (for record-keeping) and then sending the message through Signal’s messaging pipeline. The ViewModel is also responsible for presenting the result to the user, for example by showing a toast notification or alert if the send is blocked.
AWS Configuration (Info.plist) – The app’s Info.plist contains entries that configure AWS usage without hardcoding values in the code. Key parameters include:
Region (e.g., us-east-1): The AWS region where services are deployed (Lambda function, DynamoDB table, S3 bucket, Cognito pool).
CognitoIdentityPoolID: The Amazon Cognito Identity Pool ID that the app uses to obtain AWS credentials. This allows the app to assume an IAM role with permissions to invoke the Lambda and access S3/DynamoDB.
ContentFilterFunctionName: The name of the AWS Lambda function that performs the content filtering (in this case, duplicate image check). For example, this might be "AWSContentFilterFunction" (or whatever name is configured in AWS).
ContentFilterBucketName: The S3 bucket name where images should be uploaded for analysis/storage.
DuplicateThreshold: The maximum number of times an identical image is allowed to be sent. For this project, this value would be 2 (meaning two sends are allowed, and the third attempt is blocked). The client might use this to tailor the UI message, but enforcement primarily happens via the server response.
The app reads these values at runtime (using the iOS Bundle API) and uses them to configure AWS SDK clients and for logic decisions. The share extension has a similar Info.plist, likely containing the same keys, so that the extension can independently read the configuration.
AWS Integration Flow

The integration with AWS is crucial for maintaining a single source of truth for duplicate sends across devices. Here’s how the app interacts with AWS components:
Cognito Identity: On launch (or on first use of AWS services), the app initializes an AWS Cognito Identity Pool using the provided Pool ID. This yields temporary AWS credentials (Access Key, Secret, Session Token) tied to an unauthenticated or authenticated user identity. These credentials allow the app to call AWS services securely without embedding secret keys. The AWS SDK is configured with a default service configuration using these credentials (for example, setting up AWSServiceManager.default().defaultServiceConfiguration). Once configured, AWS service clients (Lambda, S3) use this behind the scenes.
Lambda Invocation: The app uses the AWS Lambda SDK to invoke the AWSContentFilterFunction by name. It constructs a payload containing the image’s SHA-256 and pHash, and possibly a user identifier (the Cognito Identity ID or a hashed user ID, so the server knows the scope). The invocation is done with a request-response mode, so the app waits for the Lambda’s result
stackoverflow.com
. The Lambda (running on AWS) is implemented to handle this payload: it checks the DynamoDB table for an item corresponding to the given user and image hash. The table might use a composite key (partition key = user ID, sort key = image hash) or a single key (the hash) with a field for user, depending on design. The Lambda reads the current count (if any) of how many times this image was sent. It then updates the count (either incrementing it or inserting a new record with count=1 if not present) in DynamoDB. Based on the updated count, the Lambda determines if the image has exceeded the allowed threshold. It returns a response back to the iOS client, typically including the updated count and a flag or message (e.g., {"duplicateCount": 3, "allow": false} or similar).
DynamoDB: Acts as the persistent store for duplicate image records. Each record includes at least the image hash and the count of sends (and likely the user or identity ID to scope the data per user). This table is shared across all of a user’s devices via the user’s identity: no matter which device (or the share extension) the user tries to send an image from, they all refer to the same DynamoDB entries. This ensures that if the user sent an image twice from their phone, sending it a third time from their tablet or via the share extension will still be caught.
S3 Upload: For each image that is allowed (not blocked), the app may upload the image to S3 through the ContentFilterService. The S3 bucket (given by ContentFilterBucketName) could be used to store the image file for additional processing. The upload uses the AWS credentials obtained via Cognito, which have permissions to put objects into the specific bucket. The app might upload the image with a key naming convention such as <userId>/<imageHash>.jpg or a GUID to avoid duplicates. This happens after the duplicate check passes, to avoid storing images that are blocked (for privacy and efficiency). In future, an AWS backend could use these stored images for further analysis (e.g., automated content moderation or manual review), but those details are beyond the duplicate filter itself.
AWS Permissions: The Cognito Identity Pool is configured with an IAM Role that grants limited permissions: it can invoke the content filter Lambda function and upload to the S3 bucket (and possibly no direct DynamoDB access, since DynamoDB is accessed by the Lambda). The Lambda function’s own role permits it to read/write the DynamoDB table. This separation ensures the client cannot directly manipulate the database except through the controlled Lambda, and the Lambda cannot be invoked by unauthorized parties. All necessary resource identifiers (pool ID, function name, bucket) are configured in the app, and changes can be made server-side without updating the app, as long as these names remain consistent.
Data Flow Sequence

To illustrate how the components work together, here’s the typical workflow when a user attempts to send an image:
User Action – The user selects an image to send in a chat (either by attaching from gallery/camera in the app, or using the iOS share extension from another app).
Hashing – The app immediately uses ImageHashing.swift to compute the image’s SHA-256 hash (for exact identification) and perceptual hash (for similarity). This might happen on a background thread to avoid UI lag.
Duplicate Check Request – The DuplicateFilterService is invoked with the computed hashes. It prepares a JSON payload with these hashes (and user identification) and calls the AWS Lambda function AWSContentFilterFunction using the AWS SDK. The function name and AWS region are taken from config. The app awaits the Lambda’s response.
Server-Side Check (Lambda + DynamoDB) – The Lambda function executes in AWS: it receives the hashes and user ID, looks up the DynamoDB table for a matching entry.
If no entry exists, it means the image has not been sent before. The Lambda will create a new record with count = 1.
If an entry exists with a count n (where n is 1 or more), it will update the count to n+1.
The Lambda determines if the updated count has reached the DuplicateThreshold (e.g., 3). If the count is 3 (meaning this was the third attempt), it will include in the response that the image is now blocked (not allowed to send).
If the count is still below the threshold (1 or 2), it marks it as allowed. (The threshold value itself could be stored server-side as well or sent along by the client; having it in Info.plist means the client is aware, but the Lambda likely also knows the business rule.)
Duplicate Check Response – The Lambda returns a response back to the iOS client via the SDK call. For example, the response might be a JSON: {"duplicateCount": 2, "allow": true} or {"duplicateCount": 3, "allow": false}. The DuplicateFilterService parses this response.
Decision & Alert – The DuplicateFilterService informs the calling code (ImageUploadViewModel) of the result.
If allowed (allow: true): The image has been sent fewer than 3 times. The ViewModel will continue the send process. It may next call ContentFilterService to upload the image to S3 (non-blocking to the user, possibly done in parallel with message sending) and then proceed to encrypt and send the image message via the Signal service as usual.
If blocked (allow: false): This means the user already sent the image twice and this third attempt is disallowed. The ViewModel will not call the normal send function. Instead, it triggers a UI alert to the user. The preferred UI is a non-intrusive toast notification that briefly appears (likely at the bottom of the screen) saying something like “Image already sent twice — cannot send again.” If a toast mechanism is not readily available, it could fall back to an alert dialog. The app does not send the image, so the chat input remains unchanged except for the alert.
Share Extension Path – If the send is happening via the share extension, the flow is similar: the extension’s code also uses ImageHashing and DuplicateFilterService (shared code) to perform the check before actually uploading or sending the content to Signal. If blocked, the extension must inform the user (possibly by displaying an alert in the extension UI or disabling the send action with a message), and abort the share process.
Throughout this flow, state about duplicate sends is primarily stored on the server (DynamoDB). The client itself does not permanently store how many times a given image was sent, relying on the authoritative DynamoDB record via the Lambda. This design ensures that whether the user reinstalls the app, switches devices, or shares from an extension, the count is consistent. The app is mostly stateless regarding duplicate counts, aside from transiently handling the current attempt’s result.
Share Extension Compatibility

The iOS share extension is implemented to use the same duplicate filtering logic without code duplication. Most of the services (hashing, duplicate check, etc.) are shared between the main app target and the extension target. To achieve this, the code is either included in both targets or factored into a common framework. The extension operates under tighter restrictions than the main app:
It runs in a separate process with limited API access. For instance, an extension cannot access the global UIApplication.shared or certain UI APIs not meant for extensions
marcoeidinger.medium.com
. Our code is designed to avoid such calls in shared logic. Any functionality that inherently uses disallowed APIs is guarded (e.g., only used in the main app context).
AWS setup in the extension: The extension has its own Info.plist with the same AWS config values, and it will initialize AWS Cognito credentials just as the main app does. Because the extension is short-lived, it may fetch new temporary credentials each time it runs, or if the AWS SDK shares credentials via keychain, it could reuse the identity established by the main app. (If using Cognito Identity, the identity ID and cached tokens can be shared via Keychain access group, so the extension likely ends up using the same user identity, ensuring DynamoDB entries are correctly scoped to the one user.)
UI differences: The extension’s UI is usually a slimmed-down share sheet interface. If a duplicate image attempt is blocked in the extension, we cannot simply present a toast on the main app window. Instead, the extension might show an UIAlertController with an error, or update its UI label to inform the user that the send was blocked. After showing the message, the extension would not forward the image to the main app. It’s important that the extension cleanly handles this situation (possibly by cancelling the share or simply doing nothing after informing the user).
We ensure that all new code is extension-safe. The project likely has the build setting APPLICATION_EXTENSION_API_ONLY = YES for the extension target (set by default), which will flag any improper API usage at compile time. The code uses conditional compilation or runtime checks if needed. For example, if any piece of code needed to use UIApplication (for instance, to get keyWindow for a toast), we would conditionally exclude that in the extension and use an alternative approach.
Interconnection of Services and State Management

All the components work together as a pipeline, coordinated by the view model:
The ImageUploadViewModel is the entry point that ties UI interaction to the services. It does minimal work itself, mostly delegating to services and then reacting to the outcome.
ImageHashing is a low-level utility with no external dependencies; it’s used by DuplicateFilterService (and potentially by any other feature needing image fingerprinting).
DuplicateFilterService depends on AWS integration – it uses the AWS Lambda client which in turn relies on the AWS credentials and configuration established at app launch. It can be considered a part of the networking layer, as it calls a cloud function.
ContentFilterService depends on both the AWS credentials (for S3) and on DuplicateFilterService (for deciding whether to proceed). In some implementations, the DuplicateFilterService might be called inside ContentFilterService’s workflow, or vice versa. A likely design is that the ViewModel calls DuplicateFilter first (to decide allow/block), then if allowed, calls ContentFilterService to handle the upload. Thus, these services are somewhat sequentially connected rather than deeply integrated with each other. They do share common config (AWS info) and credentials.
State management: The only persistent state regarding duplicates is in DynamoDB. The app itself doesn’t maintain a local database of sent image hashes. This means the source of truth is always the cloud, and any device or extension will get up-to-date info. The ephemeral state includes the current image being processed and the result of its duplicate check (which might be stored in a local variable or passed along in completion closures). There might also be a short-term caching in DuplicateFilterService (for instance, if a user tries to send the same image twice in one app session, the second time could theoretically use a cached knowledge that it was sent once already to reduce latency; however, given that the server must still be updated, the app would likely call the backend anyway to increment the count).
Extension state: The share extension, due to its transient nature, doesn’t hold long-term state. If needed, both the app and extension could share a common app group container for cache or config, but for this feature it’s not strictly necessary since the AWS backend handles state.
In summary, the architecture cleanly separates concerns:
A hashing layer (ImageHashing.swift) for image processing,
A network/logic layer (DuplicateFilterService.swift and ContentFilterService.swift) for communicating with AWS and making allow/block decisions,
And the UI layer (ImageUploadViewModel and related view/controllers) that presents outcomes to the user and ties everything into the messaging workflow.
All configuration is externalized in Info.plist, making it easy to adjust thresholds or endpoints without code changes. The share extension reuses the same logic to maintain identical behavior when sharing content externally. By leveraging AWS, the system ensures that duplicate image checks are consistent and global for the user, regardless of which device or entry point they use to send images.

### Entitlements & Provisioning  
Both the main app **and** the Share Extension must belong to the same
App Group and Keychain-sharing group so they can reuse the Cognito
identity and AWS credentials cache.

| Target | Capability                | Identifier example                 |
|--------|---------------------------|------------------------------------|
| App    | App Groups               | group.com.yourco.signal           |
| App    | Keychain Sharing         | keychain-access-group-signal      |
| Ext.   | App Groups               | group.com.yourco.signal           |
| Ext.   | Keychain Sharing         | keychain-access-group-signal      |

> ⚠️ Provisioning: create a **single** App Group-enabled profile for both
targets; the Share Extension will fail to launch if the groups diverge.

---

### Tests/ folder  
Signal-iOS/
├── Tests/
│ ├── ImageHashingTests.swift
│ ├── DuplicateFilterServiceTests.swift
│ └── UITestDuplicateBlocking.swift

Holds all unit & UI tests mentioned in *tasks.md* so CI can discover
them automatically.

---

### pHash implementation note  
We rely on **CocoaImageHashing** (SPM package `github.com/–/CocoaImageHashing`)
for perceptual hashing.  If you swap libraries, update the
`#import <CocoaImageHashing>` lines in `ImageHashing.swift` and bump the
dependency here.

---

### Sequence diagram  
Add a one-page Mermaid diagram (or PNG) illustrating:

User → App : pick image
App → ImageHashing : SHA-256 + pHash
App → Lambda : {hashes}
Lambda → DynamoDB : read/update
Lambda → App : {duplicateCount, allow}
App → S3 : upload (only if allow)
App → User : toast (if blocked) / send message (if allowed)


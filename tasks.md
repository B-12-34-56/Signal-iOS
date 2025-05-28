Add AWS SDKs to both targetsInclude AWSCognitoIdentity, AWSLambda, AWSS3 via CocoaPods or SPM.Done when: project builds for App and Share Extension with no missing symbols.

Populate Info.plist keysAWSRegion, CognitoIdentityPoolID, ContentFilterLambdaName, ContentFilterBucketName, DuplicateThreshold = 2.Done when: runtime log prints the expected values from Bundle.main.infoDictionary.

Initialise Cognito credentials

AppDelegate → set AWSServiceConfiguration with credentials provider.

Share Extension entry → repeat init in ShareViewController.viewDidLoad.Done when: AWSCognitoIdentityProvider.default().identityId() returns non‑nil on both targets.

ImageHashing.swift – SHA‑256Pure Swift/CryptoKit digest → hex string.Unit test: known data → known hash.

ImageHashing.swift – pHashIntegrate CocoaImageHashing; return 64‑bit int as hex.Unit test: similar images ⇒ Hamming distance < 5.

DuplicateCheck modelsDuplicateCheckRequest & DuplicateCheckResponse (Codable).Unit test: round‑trip JSON encode/decode.

DuplicateFilterServiceBuild JSON payload → invoke Lambda (.requestResponse) → parse response.Log {duplicateCount, allow} at .debug.Unit test: mock Lambda → returns allow / deny scenarios.

ContentFilterService – S3 uploadOnly called when allow == true. Key: <userId>/<sha>.jpg.Done when: object visible in bucket during dev run.

Wire gate in ImageUploadViewModel

Before sending, call DuplicateFilterService.

If blocked ⇒ skip send, proceed to toast (next step).Integration test: third send never reaches Signal send path.

Main‑app toastBottom‑of‑chat banner, auto‑dismiss 3 s. Text: “Image already sent twice — blocked.”UI test: toast appears on 3rd attempt; conversation unchanged.

Share Extension duplicate gateIn didSelectPost, run duplicate check → if blocked show UIAlertController → call cancelRequest(withError:).Manual test: 3rd share from Photos shows alert; share sheet closes.

Share‑extension entitlementsAdd App Group + Keychain groups; match main app.Done when: extension launches on device build with no entitlement error.

Extension‑safe sweepRemove or #if !APP_EXTENSION wrap any UIApplication.shared calls.Done when: Xcode builds with APPLICATION_EXTENSION_API_ONLY = YES.

Offline‑fallback logicDecide policy (allow send if Lambda unreachable). Implement retry/back‑off then fallback.Unit test: simulate network error → service returns allow, app sends image.

Threshold sanity‑check guardIn DuplicateFilterService, block locally when duplicateCount ≥ 3 even if allow == true (defence‑in‑depth).Unit test: feed mock response {count:3, allow:true} → service treats as blocked.

Unit tests – full service layerScenarios: first, second, third send; offline fallback; threshold mismatch.

UI test – end‑to‑end triple‑send blockAutomation sends image thrice; 3rd send blocked and toast visible.

Version bump & build numberUpdate for TestFlight.

Archive & upload to TestFlightSmoke‑test on real device (app + extension).

Docs update & repo tagTag v1.0.0-duplicate-filter and push changelog.

# Duplicate Detection MVP Build Plan for `Signal-iOS` Fork

This document lives alongside the repository and can be consumed by any engineering LLM or human contributor.

---

## 1. Repository Tree (existing + **▲ additions**)

```text
Signal-iOS/                          # repo root
├─ AWSNetwork/                       # generic networking helpers
├─ AWSUpload/                        # S3 multipart + presign helpers
├─ Config/
│   └─ Signal.xcconfig
├─ Signal/                           # UIKit / SwiftUI entry points
│   └─ …                             # unchanged
├─ SignalUI/                         # reusable view components
│   └─ DuplicateBannerView.swift ▲   # NEW – non‑blocking banner
├─ SignalServiceKit/
│   ├─ Messaging/
│   │   ├─ Attachments/
│   │   │   └─ ImageSignature.swift ▲   # NEW – SHA‑256 utility
│   │   └─ DuplicateDetection/ ▲        # NEW subtree
│   │       ├─ DuplicateService.swift
│   │       ├─ SignatureMemoryCache.swift
│   │       └─ SignatureDiskCache.swift  # GRDB‑backed
│   └─ AWS/
│       ├─ DuplicateAPI.swift ▲      # thin wrapper over AWSNetwork
│       └─ CognitoAuthProvider.swift ▲
├─ SignalTests/
│   └─ DuplicateDetectionTests/ ▲    # unit tests
├─ Scripts/
│   └─ localstack-start.sh ▲         # helper for integration tests
└─ infra/ ▲                          # AWS CDK stacks
    ├─ storage-stack.ts
    ├─ api-stack.ts
    └─ auth-stack.ts
```

---

## 2. Atomic, Test‑First Task Queue

| # | Task (one concern) | Start | End / Acceptance Test |
|---|--------------------|-------|-----------------------|
| **0.1** | **Scaffold `DuplicateDetectionTests` target** | Create `SignalTests/DuplicateDetectionTests` | `xcodebuild test` passes (0 tests) |
| **0.2** | **Stub `ImageSignature.swift` with `sha256(_:)`** | Add file in `Messaging/Attachments/` | Unit‑test hashes fixture → known hex |
| **0.3** | **Create `SignatureMemoryCache.swift` (`NSCache`)** | Add file, not wired | Unit‑test: insert + eviction after `countLimit` |
| **0.4** | **Create `SignatureDiskCache.swift` (GRDB)** | Add file | Unit‑test: write, then new process read |
| **0.5** | **Implement `DuplicateService.swift` with local cache check** | Wire caches | Unit‑test: hit, miss→disk, miss→false |
| **1.1** | **Inject `DuplicateService` into `ConversationViewController`** | Register singleton via existing DI | Manual: app launches |
| **1.2** | **Add `DuplicateBannerView.swift`** | Create view | Toggle in preview shows banner |
| **1.3** | **Hook image‑picker flow** | Modify controller | Manual: pick same photo twice → banner appears |
| **2.1** | **Create `infra/storage-stack.ts` (S3 + Dynamo)** | CDK synth | Snapshot test matches |
| **2.2** | **Create `infra/api-stack.ts` (GET/POST) + Lambdas** | CDK synth | Routes appear in diff |
| **2.3** | **Add `checkDuplicate` & `writeDuplicate` lambdas** | Code + jest | Local tests 100 % pass |
| **2.4** | **Deploy dev stack** | `cdk deploy` | Endpoint URL recorded in README |
| **3.1** | **Create `DuplicateAPI.swift`** | Uses AWSNetwork | Unit‑test with stubbed server (404/409) |
| **3.2** | **Extend `DuplicateService` to remote check** | Inject API client | Unit‑test using mock server |
| **3.3** | **Modify send‑pipeline to block duplicates** | One‑line guard | Manual: duplicate send blocked |
| **3.4** | **Implement `S3Uploader.upload(data:)`** | Wrap existing AWSUpload | Unit‑test PUT to stub URL |
| **3.5** | **Call `DuplicateAPI.register` post‑upload** | Update service | Integration test with LocalStack |
| **4.1** | **Add Cognito unauth role in `auth-stack.ts` & `CognitoAuthProvider.swift`** | CDK + Swift | App receives Id token (log) |
| **4.2** | **Retry decorator (max 3) around DuplicateAPI** | Utility | Unit‑test: fail twice, succeed third |
| **5.1** | **UI state‑machine tests** | Write test | Sequence A, B, A ⇒ `[ok, ok, duplicate]` |
| **5.2** | **GitHub Actions CI** | `.github/workflows/ci.yml` | Badge green |
| **5.3** | **Tag `v0.1.0‑mvp`** | git tag | Tag pushed, all tests green |

> **Total tasks: 23**  
> Execute sequentially—merge only when the current task’s test (unit, integration, or manual) passes.

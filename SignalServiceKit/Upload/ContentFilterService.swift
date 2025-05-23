import Foundation
import AWSCore
import AWSS3

@objcMembers
final class ContentFilterService: NSObject {

    static let shared = ContentFilterService()

    private let bucket  = "signal-malware-scan"
    private let tagKey  = "malware"
    private let clean   = Set(["clean", "none"])

    private lazy var s3: AWSS3 = {
        let poolID = Bundle.main
              .object(forInfoDictionaryKey: "AWSCognitoIdentityPoolID") as! String
        let region = AWSRegionType.USEast1   // keep in sync with Config.plist
        let creds  = AWSCognitoCredentialsProvider(regionType: region,
                                                   identityPoolId: poolID)
        let cfg    = AWSServiceConfiguration(region: region,
                                             credentialsProvider: creds)!
        AWSS3.register(with: cfg, forKey: "FilterS3")
        return AWSS3(forKey: "FilterS3")
    }()

    enum Decision { case approved(URL); case rejected(String); case failure(Error) }

    func evaluate(localURL: URL,
                  progress: ((Double)->Void)? = nil,
                  done: @escaping (Decision)->Void) {

        let key   = UUID().uuidString
        let expr  = AWSS3TransferUtilityUploadExpression()
        expr.progressBlock = { _, p in progress?(p.fractionCompleted) }

        AWSS3TransferUtility.default().uploadFile(localURL,
                                                  bucket: bucket,
                                                  key: key,
                                                  contentType: "image/jpeg",
                                                  expression: expr) { _, err in
            if let err = err { done(.failure(err)); return }
            self.poll(for: key, tries: 0, done: done)
        }
    }

    private func poll(for key: String, tries: Int,
                      done: @escaping (Decision)->Void) {

        guard tries < 10 else {
            done(.failure(NSError(domain:"Filter", code:-1,
                       userInfo:[NSLocalizedDescriptionKey: "Timed out"])))
            return
        }
        let req = AWSS3GetObjectTaggingRequest()!
        req.bucket = bucket
        req.key = key
        s3.getObjectTagging(req).continueWith { task in
            if let e = task.error       { done(.failure(e)) }
            else if
              let tag = task.result?.tagSet?
                        .first(where: {$0.key == self.tagKey})?.value {
                    self.clean.contains(tag)
                    ? done(.approved(URL(string:"s3://\(self.bucket)/\(key)")!))
                    : done(.rejected(tag))
            } else {                                // not tagged yet → retry
                DispatchQueue.global().asyncAfter(deadline:.now()+3) {
                    self.poll(for: key, tries: tries+1, done: done)
                }
            }
            return nil
        }
    }
} 

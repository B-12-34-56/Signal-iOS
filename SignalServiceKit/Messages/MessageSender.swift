//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import UIKit
import os.log

// MARK: - Message "isXYZ" properties

private extension TSOutgoingMessage {
    var isTransientSKDM: Bool {
        (self as? OWSOutgoingSenderKeyDistributionMessage)?.isSentOnBehalfOfOnlineMessage ?? false
    }

    var isResendRequest: Bool {
        self is OWSOutgoingResendRequest
    }

    var isSyncMessage: Bool { self is OWSOutgoingSyncMessage }

    var canSendToLocalAddress: Bool {
        return (isSyncMessage ||
                self is OWSOutgoingCallMessage ||
                self is OWSOutgoingResendRequest ||
                self is OWSOutgoingResendResponse)
    }
}

// MARK: - MessageSender

public class MessageSender {

    private var preKeyManager: PreKeyManager { DependenciesBridge.shared.preKeyManager }

    private let groupSendEndorsementStore: any GroupSendEndorsementStore

    init(groupSendEndorsementStore: any GroupSendEndorsementStore) {
        self.groupSendEndorsementStore = groupSendEndorsementStore

        SwiftSingletons.register(self)
    }

    private let pendingTasks = PendingTasks(label: "Message Sends")

    public func pendingSendsPromise() -> Promise<Void> {
        // This promise blocks on all operations already in the queue,
        // but will not block on new operations added after this promise
        // is created. That's intentional to ensure that NotificationService
        // instances complete in a timely way.
        pendingTasks.pendingTasksPromise()
    }

    // MARK: - Creating Signal Protocol Sessions

    private func containsValidSession(for serviceId: ServiceId, deviceId: DeviceId, tx: DBReadTransaction) throws -> Bool {
        let sessionStore = DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore
        do {
            guard let session = try sessionStore.loadSession(for: serviceId, deviceId: deviceId, tx: tx) else {
                return false
            }
            return session.hasCurrentState
        } catch {
            switch error {
            case RecipientIdError.mustNotUsePniBecauseAciExists:
                throw error
            default:
                return false
            }
        }
    }

    /// Establishes a session with the recipient if one doesn't already exist.
    private func ensureRecipientHasSession(
        recipientUniqueId: RecipientUniqueId,
        serviceId: ServiceId,
        deviceId: DeviceId,
        isOnlineMessage: Bool,
        isTransientSenderKeyDistributionMessage: Bool,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws {
        let hasSession = try SSKEnvironment.shared.databaseStorageRef.read { tx in
            try containsValidSession(for: serviceId, deviceId: deviceId, tx: tx)
        }
        if hasSession {
            return
        }

        let preKeyBundle = try await makePrekeyRequest(
            recipientUniqueId: recipientUniqueId,
            serviceId: serviceId,
            deviceId: deviceId,
            isOnlineMessage: isOnlineMessage,
            isTransientSenderKeyDistributionMessage: isTransientSenderKeyDistributionMessage,
            sealedSenderParameters: sealedSenderParameters
        )

        try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            try self.createSession(
                for: preKeyBundle,
                recipientUniqueId: recipientUniqueId,
                serviceId: serviceId,
                deviceId: deviceId,
                transaction: tx
            )
        }
    }

    private func makePrekeyRequest(
        recipientUniqueId: RecipientUniqueId?,
        serviceId: ServiceId,
        deviceId: DeviceId,
        isOnlineMessage: Bool,
        isTransientSenderKeyDistributionMessage: Bool,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws -> SignalServiceKit.PreKeyBundle {
        Logger.info("serviceId: \(serviceId).\(deviceId)")

        // As an optimization, skip the request if an error is guaranteed.
        if willDefinitelyHaveUntrustedIdentityError(for: serviceId) {
            Logger.info("Skipping prekey request due to untrusted identity.")
            throw UntrustedIdentityError(serviceId: serviceId)
        }

        if let recipientUniqueId, willLikelyHaveInvalidKeySignatureError(for: recipientUniqueId) {
            Logger.info("Skipping prekey request due to invalid prekey signature.")

            // Check if this error is happening repeatedly for this recipientUniqueId.
            // If so, return an InvalidKeySignatureError as a terminal failure.
            throw InvalidKeySignatureError(serviceId: serviceId, isTerminalFailure: true)
        }

        if isOnlineMessage || isTransientSenderKeyDistributionMessage {
            Logger.info("Skipping prekey request for transient message")
            throw MessageSenderNoSessionForTransientMessageError()
        }

        var requestOptions: RequestMaker.Options = [.waitForWebSocketToOpen]

        // If we're sending a story, we can use the identified connection to fetch
        // pre keys and the unidentified connection to send the message. For other
        // types of messages, we expect unidentified message sends to fail if we
        // can't fetch pre keys via the unidentified connection.
        if let sealedSenderParameters, sealedSenderParameters.message.isStorySend {
            requestOptions.insert(.allowIdentifiedFallback)
        }

        let requestMaker = RequestMaker(
            label: "Prekey Fetch",
            serviceId: serviceId,
            canUseStoryAuth: false,
            accessKey: sealedSenderParameters?.accessKey,
            endorsement: sealedSenderParameters?.endorsement,
            authedAccount: .implicit(),
            options: requestOptions
        )

        do {
            let result = try await requestMaker.makeRequest {
                return OWSRequestFactory.recipientPreKeyRequest(serviceId: serviceId, deviceId: deviceId, auth: $0)
            }
            guard let responseData = result.response.responseBodyData else {
                throw OWSAssertionError("Prekey fetch missing response object.")
            }
            guard let bundle = try? JSONDecoder().decode(SignalServiceKit.PreKeyBundle.self, from: responseData) else {
                throw OWSAssertionError("Prekey fetch returned an invalid bundle.")
            }
            return bundle
        } catch {
            switch error.httpStatusCode {
            case 404:
                throw MessageSenderError.missingDevice
            case 429:
                throw MessageSenderError.prekeyRateLimit
            default:
                throw error
            }
        }
    }

    private func createSession(
        for preKeyBundle: SignalServiceKit.PreKeyBundle,
        recipientUniqueId: String,
        serviceId: ServiceId,
        deviceId: DeviceId,
        transaction: DBWriteTransaction
    ) throws {
        assert(!Thread.isMainThread)

        if try containsValidSession(for: serviceId, deviceId: deviceId, tx: transaction) {
            Logger.warn("Session already exists for \(serviceId), deviceId: \(deviceId).")
            return
        }

        guard let deviceBundle = preKeyBundle.devices.first(where: { $0.deviceId == deviceId }) else {
            throw OWSAssertionError("Server didn't provide a bundle for the requested device.")
        }

        Logger.info("Creating session for \(serviceId), deviceId: \(deviceId); signed \(deviceBundle.signedPreKey.keyId), one-time \(deviceBundle.preKey?.keyId as Optional), kyber \(deviceBundle.pqPreKey?.keyId as Optional)")

        let bundle: LibSignalClient.PreKeyBundle
        if let preKey = deviceBundle.preKey {
            if let pqPreKey = deviceBundle.pqPreKey {
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: deviceBundle.registrationId,
                    deviceId: deviceId.uint32Value,
                    prekeyId: preKey.keyId,
                    prekey: preKey.publicKey,
                    signedPrekeyId: deviceBundle.signedPreKey.keyId,
                    signedPrekey: deviceBundle.signedPreKey.publicKey,
                    signedPrekeySignature: deviceBundle.signedPreKey.signature,
                    identity: preKeyBundle.identityKey,
                    kyberPrekeyId: pqPreKey.keyId,
                    kyberPrekey: pqPreKey.publicKey,
                    kyberPrekeySignature: pqPreKey.signature
                )
            } else {
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: deviceBundle.registrationId,
                    deviceId: deviceId.uint32Value,
                    prekeyId: preKey.keyId,
                    prekey: preKey.publicKey,
                    signedPrekeyId: deviceBundle.signedPreKey.keyId,
                    signedPrekey: deviceBundle.signedPreKey.publicKey,
                    signedPrekeySignature: deviceBundle.signedPreKey.signature,
                    identity: preKeyBundle.identityKey
                )
            }
        } else {
            if let pqPreKey = deviceBundle.pqPreKey {
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: deviceBundle.registrationId,
                    deviceId: deviceId.uint32Value,
                    signedPrekeyId: deviceBundle.signedPreKey.keyId,
                    signedPrekey: deviceBundle.signedPreKey.publicKey,
                    signedPrekeySignature: deviceBundle.signedPreKey.signature,
                    identity: preKeyBundle.identityKey,
                    kyberPrekeyId: pqPreKey.keyId,
                    kyberPrekey: pqPreKey.publicKey,
                    kyberPrekeySignature: pqPreKey.signature
                )
            } else {
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: deviceBundle.registrationId,
                    deviceId: deviceId.uint32Value,
                    signedPrekeyId: deviceBundle.signedPreKey.keyId,
                    signedPrekey: deviceBundle.signedPreKey.publicKey,
                    signedPrekeySignature: deviceBundle.signedPreKey.signature,
                    identity: preKeyBundle.identityKey
                )
            }
        }

        do {
            let identityManager = DependenciesBridge.shared.identityManager
            let protocolAddress = ProtocolAddress(serviceId, deviceId: deviceId.uint32Value)
            try processPreKeyBundle(
                bundle,
                for: protocolAddress,
                sessionStore: DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore,
                identityStore: identityManager.libSignalStore(for: .aci, tx: transaction),
                context: transaction
            )
        } catch SignalError.untrustedIdentity(_), IdentityManagerError.identityKeyMismatchForOutgoingMessage {
            Logger.warn("Found untrusted identity for \(serviceId)")
            handleUntrustedIdentityKeyError(
                serviceId: serviceId,
                recipientUniqueId: recipientUniqueId,
                preKeyBundle: preKeyBundle,
                transaction: transaction
            )
            throw UntrustedIdentityError(serviceId: serviceId)
        } catch SignalError.invalidSignature(_) {
            Logger.error("Invalid key signature for \(serviceId)")

            // Received this error from the server, so this could either be
            // an invalid key due to a broken client, or it may be a random
            // corruption in transit.  Mark having encountered an error for
            // this recipient so later checks can determine if this has happend
            // more than once and fail early.
            // The error thrown here is considered non-terminal which allows
            // the request to be retried.
            hadInvalidKeySignatureError(for: recipientUniqueId)
            throw InvalidKeySignatureError(serviceId: serviceId, isTerminalFailure: false)
        }
        owsAssertDebug(try containsValidSession(for: serviceId, deviceId: deviceId, tx: transaction), "Couldn't create session.")
    }

    // MARK: - Untrusted Identities

    private func handleUntrustedIdentityKeyError(
        serviceId: ServiceId,
        recipientUniqueId: RecipientUniqueId,
        preKeyBundle: SignalServiceKit.PreKeyBundle,
        transaction tx: DBWriteTransaction
    ) {
        let identityManager = DependenciesBridge.shared.identityManager
        identityManager.saveIdentityKey(preKeyBundle.identityKey, for: serviceId, tx: tx)
    }

    /// If true, we expect fetching a bundle will fail no matter what it contains.
    ///
    /// If we're noLongerVerified, nothing we fetch can alter the state. The
    /// user must manually accept the new identity key and then retry the
    /// message.
    ///
    /// If we're implicit & it's not trusted, it means it changed recently. It
    /// would work if we waited a few seconds, but we want to surface the error
    /// to the user.
    ///
    /// Even though it's only a few seconds, we must not talk to the server in
    /// the implicit case because there could be many messages queued up that
    /// would all try to fetch their own bundle.
    private func willDefinitelyHaveUntrustedIdentityError(for serviceId: ServiceId) -> Bool {
        assert(!Thread.isMainThread)

        // Prekey rate limits are strict. Therefore, we want to avoid requesting
        // prekey bundles that can't be processed. After a prekey request, we might
        // not be able to process it if the new identity key isn't trusted.

        let identityManager = DependenciesBridge.shared.identityManager
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            return identityManager.untrustedIdentityForSending(
                to: SignalServiceAddress(serviceId),
                untrustedThreshold: nil,
                tx: tx
            ) != nil
        }
    }

    // MARK: - Invalid Signatures

    private typealias InvalidSignatureCache = [RecipientUniqueId: InvalidSignatureCacheItem]
    private struct InvalidSignatureCacheItem {
        let lastErrorDate: Date
        let errorCount: UInt32
    }
    private let invalidKeySignatureCache = AtomicValue(InvalidSignatureCache(), lock: .init())

    private func hadInvalidKeySignatureError(for recipientUniqueId: RecipientUniqueId) {
        invalidKeySignatureCache.update { cache in
            var errorCount: UInt32 = 1
            if let mostRecentError = cache[recipientUniqueId] {
                errorCount = mostRecentError.errorCount + 1
            }

            cache[recipientUniqueId] = InvalidSignatureCacheItem(
                lastErrorDate: Date(),
                errorCount: errorCount
            )
        }
    }

    private func willLikelyHaveInvalidKeySignatureError(for recipientUniqueId: RecipientUniqueId) -> Bool {
        assert(!Thread.isMainThread)

        // Similar to untrusted identity errors, when an invalid signature for a prekey
        // is encountered, it will probably be encountered for a while until the
        // target client rotates prekeys and hopfully fixes the bad signature.
        // To avoid running into prekey rate limits, remember when an error is
        // encountered and slow down sending prekey requests for this recipient.
        //
        // Additionally, there is always a chance of corruption of the prekey
        // bundle during data transmission, which would result in an invalid
        // signature of an otherwise correct bundle. To handle this rare case,
        // don't begin limiting the prekey request until after encounting the
        // second bad signature for a particular recipient.

        guard let mostRecentError = invalidKeySignatureCache.get()[recipientUniqueId] else {
            return false
        }

        let staleIdentityLifetime: TimeInterval = .minute * 5
        guard abs(mostRecentError.lastErrorDate.timeIntervalSinceNow) < staleIdentityLifetime else {

            // Error has expired, remove it to reset the count
            invalidKeySignatureCache.update { cache in
                _ = cache.removeValue(forKey: recipientUniqueId)
            }

            return false
        }

        // Let the first error go, only skip starting on the second error
        guard mostRecentError.errorCount > 1 else {
            return false
        }

        return true
    }

    // MARK: - Sending Attachments

    public func sendTransientContactSyncAttachment(
        dataSource: DataSource,
        localThread: TSContactThread
    ) async throws {
        guard let uploadManager = DependenciesBridge.shared.attachmentUploadManager else {
            throw MessageSenderError.attachmentUploadManagerUnavailable
        }
        let uploadResult = try await uploadManager.uploadTransientAttachment(
            dataSource: dataSource
        )
        let message = SSKEnvironment.shared.databaseStorageRef.read { tx in
            return OWSSyncContactsMessage(uploadedAttachment: uploadResult, localThread: localThread, tx: tx)
        }
        let preparedMessage = PreparedOutgoingMessage.preprepared(contactSyncMessage: message)
        let result = await Result { try await sendMessage(preparedMessage) }
        try result.get()
    }

    // MARK: - Constructing Message Sends

    public func sendMessage(_ preparedOutgoingMessage: PreparedOutgoingMessage) async throws {
        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            preparedOutgoingMessage.updateAllUnsentRecipientsAsSending(tx: tx)
        }

        Logger.info("Sending \(preparedOutgoingMessage)")

        // We create a PendingTask so we can block on flushing all current message sends.
        let pendingTask = pendingTasks.buildPendingTask(label: "Message Send")
        defer { pendingTask.complete() }

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            let uploadOperations = SSKEnvironment.shared.databaseStorageRef.read { tx in
                preparedOutgoingMessage.attachmentUploadOperations(tx: tx)
            }
            for uploadOperation in uploadOperations {
                taskGroup.addTask {
                    try await Upload.uploadQueue.run(uploadOperation)
                }
            }
            try await taskGroup.waitForAll()
        }

        try await preparedOutgoingMessage.send(self.sendPreparedMessage(_:))
    }

    private func waitForPreKeyRotationIfNeeded() async throws {
        while let taskToWaitFor = preKeyRotationTaskIfNeeded() {
            try await taskToWaitFor.value
        }
    }

    private let pendingPreKeyRotation = AtomicValue<Task<Void, Error>?>(nil, lock: .init())

    private func preKeyRotationTaskIfNeeded() -> Task<Void, Error>? {
        return pendingPreKeyRotation.map { existingTask in
            if let existingTask {
                return existingTask
            }
            let shouldRunPreKeyRotation = SSKEnvironment.shared.databaseStorageRef.read { tx in
                preKeyManager.isAppLockedDueToPreKeyUpdateFailures(tx: tx)
            }
            if shouldRunPreKeyRotation {
                Logger.info("Rotating signed pre-key before sending message.")
                // Retry prekey update every time user tries to send a message while app is
                // disabled due to prekey update failures.
                //
                // Only try to update the signed prekey; updating it is sufficient to
                // re-enable message sending.
                return Task {
                    try await self.preKeyManager.rotateSignedPreKeys().value
                    self.pendingPreKeyRotation.set(nil)
                }
            }
            return nil
        }
    }

    // Mark skipped recipients as such. We may skip because:
    //
    // * A recipient is no longer in the group.
    // * A recipient is blocked.
    // * A recipient is unregistered.
    // * A recipient does not have the required capability.
    private func markSkippedRecipients(
        of message: TSOutgoingMessage,
        sendingRecipients: [ServiceId],
        tx: DBWriteTransaction
    ) {
        let skippedRecipients = Set(message.sendingRecipientAddresses())
            .subtracting(sendingRecipients.lazy.map { SignalServiceAddress($0) })
        for address in skippedRecipients {
            // Mark this recipient as "skipped".
            message.updateWithSkippedRecipient(address, transaction: tx)
        }
    }

    private func unsentRecipients(
        of message: TSOutgoingMessage,
        in thread: TSThread,
        localIdentifiers: LocalIdentifiers,
        tx: DBReadTransaction
    ) throws -> [SignalServiceAddress] {
        if message.isSyncMessage {
            return [localIdentifiers.aciAddress]
        }

        if let groupThread = thread as? TSGroupThread {
            // Send to the intersection of:
            //
            // * "sending" recipients of the message.
            // * members of the group.
            //
            // I.e. try to send a message IFF:
            //
            // * The recipient was in the group when the message was first tried to be sent.
            // * The recipient is still in the group.
            // * The recipient is in the "sending" state.

            var recipientAddresses = Set<SignalServiceAddress>()

            recipientAddresses.formUnion(message.sendingRecipientAddresses())

            // Only send to members in the latest known group member list.
            // If a member has left the group since this message was enqueued,
            // they should not receive the message.
            let groupMembership = groupThread.groupModel.groupMembership
            var currentValidRecipients = groupMembership.fullMembers

            // ...or latest known list of "additional recipients".
            if GroupManager.shouldMessageHaveAdditionalRecipients(message, groupThread: groupThread) {
                currentValidRecipients.formUnion(groupMembership.invitedMembers)
            }
            currentValidRecipients.remove(localIdentifiers.aciAddress)
            recipientAddresses.formIntersection(currentValidRecipients)

            let blockedAddresses = SSKEnvironment.shared.blockingManagerRef.blockedAddresses(transaction: tx)
            recipientAddresses.subtract(blockedAddresses)

            return Array(recipientAddresses)
        } else if let contactAddress = (thread as? TSContactThread)?.contactAddress {
            // Treat 1:1 sends to blocked contacts as failures.
            // If we block a user, don't send 1:1 messages to them. The UI
            // should prevent this from occurring, but in some edge cases
            // you might, for example, have a pending outgoing message when
            // you block them.
            if SSKEnvironment.shared.blockingManagerRef.isAddressBlocked(contactAddress, transaction: tx) {
                Logger.info("Skipping 1:1 send to blocked contact: \(contactAddress).")
                throw MessageSenderError.blockedContactRecipient
            } else {
                return [contactAddress]
            }
        } else {
            // Send to the intersection of:
            //
            // * "sending" recipients of the message.
            // * recipients of the thread
            //
            // I.e. try to send a message IFF:
            //
            // * The recipient was part of the thread when the message was first tried to be sent.
            // * The recipient is still part of the thread.
            // * The recipient is in the "sending" state.

            var recipientAddresses = Set(message.sendingRecipientAddresses())

            // Only send to members in the latest known thread recipients list.
            let currentValidThreadRecipients = thread.recipientAddresses(with: tx)

            recipientAddresses.formIntersection(currentValidThreadRecipients)

            let blockedAddresses = SSKEnvironment.shared.blockingManagerRef.blockedAddresses(transaction: tx)
            recipientAddresses.subtract(blockedAddresses)

            if recipientAddresses.contains(localIdentifiers.aciAddress) {
                owsFailDebug("Message send recipients should not include self.")
            }

            return Array(recipientAddresses)
        }
    }

    private static func partitionAddresses(_ addresses: [SignalServiceAddress]) -> ([ServiceId], [E164]) {
        var serviceIds = [ServiceId]()
        var phoneNumbers = [E164]()

        for address in addresses {
            if let serviceId = address.serviceId {
                serviceIds.append(serviceId)
            } else if let phoneNumber = address.e164 {
                phoneNumbers.append(phoneNumber)
            } else {
                owsFailDebug("Recipient has neither ServiceId nor E164.")
            }
        }

        return (serviceIds, phoneNumbers)
    }

    private func lookUpPhoneNumbers(_ phoneNumbers: [E164]) async throws {
        _ = try await SSKEnvironment.shared.contactDiscoveryManagerRef.lookUp(
            phoneNumbers: Set(phoneNumbers.lazy.map { $0.stringValue }),
            mode: .outgoingMessage
        )
    }

    private func areAttachmentsUploadedWithSneakyTransaction(for message: TSOutgoingMessage) -> Bool {
        if message.shouldBeSaved == false {
            // Unsaved attachments come in two types:
            // * no attachments
            // * contact sync, already-uploaded attachment required on init
            // So checking for upload state for unsaved attachments is pointless
            // (and will, in fact, fail, because of foreign key constraints).
            return true
        }
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            for attachment in message.allAttachments(transaction: tx) {
                guard attachment.isUploadedToTransitTier else {
                    return false
                }
            }
            return true
        }
    }

    private func sendPreparedMessage(_ message: TSOutgoingMessage) async throws {
        if !areAttachmentsUploadedWithSneakyTransaction(for: message) {
            throw OWSUnretryableMessageSenderError()
        }
        if DependenciesBridge.shared.appExpiry.isExpired {
            throw AppExpiredError()
        }
        if DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered.negated {
            throw AppDeregisteredError()
        }
        if message.shouldBeSaved {
            let latestCopy = SSKEnvironment.shared.databaseStorageRef.read { tx in
                TSInteraction.anyFetch(uniqueId: message.uniqueId, transaction: tx) as? TSOutgoingMessage
            }
            guard let latestCopy, latestCopy.wasRemotelyDeleted.negated else {
                throw MessageDeletedBeforeSentError()
            }
        }
        if DebugFlags.messageSendsFail.get() {
            throw OWSUnretryableMessageSenderError()
        }
        do {
            try await waitForPreKeyRotationIfNeeded()
            let senderCertificates = try await SSKEnvironment.shared.udManagerRef.fetchSenderCertificates(certificateExpirationPolicy: .permissive)
            try await sendPreparedMessage(
                message,
                recoveryState: OuterRecoveryState(),
                senderCertificates: senderCertificates
            )
        } catch {
            if message.wasSentToAnyRecipient {
                // Always ignore the sync error...
                try? await handleMessageSentLocally(message)
            }
            // ...so that we can throw the original error for the caller. (Note that we
            // throw this error even if the sync message is sent successfully.)
            throw error
        }
        try await handleMessageSentLocally(message)
    }

    private enum SendMessageNextAction {
        /// Look up missing phone numbers & then try sending again.
        case lookUpPhoneNumbersAndTryAgain([E164])

        /// Fetch a new set of GSEs & then try sending again.
        case fetchGroupSendEndorsementsAndTryAgain(GroupSecretParams)

        /// Perform the `sendPreparedMessage` step.
        case sendPreparedMessage(PreparedState)

        struct PreparedState {
            let serializedMessage: SerializedMessage
            let thread: TSThread
            let fanoutRecipients: [ServiceId]
            let sendViaSenderKey: (@Sendable () async -> [(ServiceId, any Error)])?
            let senderCertificate: SenderCertificate
            let udAccess: [ServiceId: OWSUDAccess]
            let endorsements: GroupSendEndorsements?
            let localIdentifiers: LocalIdentifiers
        }
    }

    /// Certain errors are "correctable" and result in immediate retries. For
    /// example, if there's a newly-added device, we should encrypt the message
    /// for that device and try to send it immediately. However, some of these
    /// errors can *theoretically* happen ad nauseam (but they shouldn't). To
    /// avoid tight retry loops, we handle them immediately just once and then
    /// use the standard retry logic if they happen repeatedly.
    private struct OuterRecoveryState {
        var canLookUpPhoneNumbers = true
        var canRefreshExpiringGroupSendEndorsements = true

        // Sender key sends will fail if a single recipient has an invalid access
        // token, but the server can't identify the recipient for us. To recover,
        // fall back to a fanout; this will fail only for the affect recipient.
        var canUseMultiRecipientSealedSender = true

        var canHandleMultiRecipientMismatchedDevices = true
        var canHandleMultiRecipientStaleDevices = true

        func mutated(_ block: (inout Self) -> Void) -> Self {
            var mutableSelf = self
            block(&mutableSelf)
            return mutableSelf
        }
    }

    private func sendPreparedMessage(
        _ message: TSOutgoingMessage,
        recoveryState: OuterRecoveryState,
        senderCertificates: SenderCertificates
    ) async throws {
        let nextAction = try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx -> SendMessageNextAction? in
            guard let thread = message.thread(tx: tx) else {
                throw MessageSenderError.threadMissing
            }

            let canSendToThread: Bool = {
                if message is OWSOutgoingReactionMessage {
                    return thread.canSendReactionToThread
                }
                let isChatMessage = (
                    (
                        message.shouldBeSaved
                        && message.insertedMessageHasRenderableContent(rowId: message.sqliteRowId!, tx: tx)
                    )
                    || message is OutgoingGroupCallUpdateMessage
                    || message is OWSOutgoingCallMessage
                )
                return isChatMessage ? thread.canSendChatMessagesToThread() : thread.canSendNonChatMessagesToThread
            }()
            guard canSendToThread else {
                if message.shouldBeSaved {
                    throw OWSAssertionError("Sending to thread blocked.")
                }
                // Pretend to succeed for non-visible messages like read receipts, etc.
                return nil
            }

            let tsAccountManager = DependenciesBridge.shared.tsAccountManager
            guard let localIdentifiers = tsAccountManager.localIdentifiers(tx: tx) else {
                throw OWSAssertionError("Not registered.")
            }

            let proposedAddresses = try self.unsentRecipients(of: message, in: thread, localIdentifiers: localIdentifiers, tx: tx)
            let (serviceIds, phoneNumbersToFetch) = Self.partitionAddresses(proposedAddresses)

            // If we haven't yet tried to look up phone numbers, send an asynchronous
            // request to look up phone numbers, and then try to go through this logic
            // *again* in a new transaction. Things may change for that subsequent
            // attempt, and if there's still missing phone numbers at that point, we'll
            // skip them for this message.
            if recoveryState.canLookUpPhoneNumbers, !phoneNumbersToFetch.isEmpty {
                return .lookUpPhoneNumbersAndTryAgain(phoneNumbersToFetch)
            }

            self.markSkippedRecipients(of: message, sendingRecipients: serviceIds, tx: tx)

            if let contactThread = thread as? TSContactThread {
                // In the "self-send" aka "Note to Self" special case, we only need to send
                // certain kinds of messages. (In particular, regular data messages are
                // sent via their implicit sync message only.)
                if contactThread.contactAddress.isLocalAddress, !message.canSendToLocalAddress {
                    owsAssertDebug(serviceIds.count == 1)
                    Logger.info("Dropping \(type(of: message)) sent to local address (it should be sent by sync message)")
                    // Don't mark self-sent messages as read (or sent) until the sync transcript is sent.
                    return nil
                }
            }

            if serviceIds.isEmpty {
                // All recipients are already sent or can be skipped. NOTE: We might still
                // need to send a sync transcript.
                return nil
            }

            guard let serializedMessage = self.buildAndRecordMessage(message, in: thread, tx: tx) else {
                throw OWSAssertionError("Couldn't build message.")
            }

            let senderCertificate: SenderCertificate = {
                switch SSKEnvironment.shared.udManagerRef.phoneNumberSharingMode(tx: tx).orDefault {
                case .everybody:
                    return senderCertificates.defaultCert
                case .nobody:
                    return senderCertificates.uuidOnlyCert
                }
            }()

            let udAccessMap = self.fetchSealedSenderAccess(
                for: serviceIds,
                message: message,
                senderCertificate: senderCertificate,
                localIdentifiers: localIdentifiers,
                tx: tx
            )

            let endorsements: GroupSendEndorsements?
            do {
                if let secretParams = try? ((thread as? TSGroupThread)?.groupModel as? TSGroupModelV2)?.secretParams() {
                    let threadId = thread.sqliteRowId!
                    endorsements = try fetchEndorsements(forThreadId: threadId, secretParams: secretParams, tx: tx)
                    if
                        recoveryState.canRefreshExpiringGroupSendEndorsements,
                        endorsements == nil || endorsements!.expiration.timeIntervalSinceNow < 2 * .hour
                    {
                        Logger.warn("Refetching GSEs for \(thread.logString) that are missing or about to expire.")
                        return .fetchGroupSendEndorsementsAndTryAgain(secretParams)
                    }
                } else {
                    endorsements = nil
                }
            } catch {
                owsFailDebug("Continuing without GSEs that couldn't be fetched: \(error)")
                endorsements = nil
            }

            let senderKeyRecipients: [ServiceId]
            let sendViaSenderKey: (@Sendable () async -> [(ServiceId, any Error)])?
            if recoveryState.canUseMultiRecipientSealedSender, thread.usesSenderKey {
                (senderKeyRecipients, sendViaSenderKey) = self.prepareSenderKeyMessageSend(
                    for: serviceIds,
                    in: thread,
                    message: message,
                    serializedMessage: serializedMessage,
                    endorsements: endorsements,
                    udAccessMap: udAccessMap,
                    senderCertificate: senderCertificate,
                    localIdentifiers: localIdentifiers,
                    tx: tx
                )
            } else {
                senderKeyRecipients = []
                sendViaSenderKey = nil
            }

            if let thread = thread as? TSGroupThread, sendViaSenderKey == nil {
                let fullMembers = Set(thread.groupMembership.fullMembers.compactMap(\.serviceId))
                if fullMembers.intersection(serviceIds).count >= 2 {
                    let notificationPresenter = SSKEnvironment.shared.notificationPresenterRef
                    notificationPresenter.notifyTestPopulation(ofErrorMessage: "Couldn't send using GSEs.")
                }
            }

            return .sendPreparedMessage(SendMessageNextAction.PreparedState(
                serializedMessage: serializedMessage,
                thread: thread,
                fanoutRecipients: Array(Set(serviceIds).subtracting(senderKeyRecipients)),
                sendViaSenderKey: sendViaSenderKey,
                senderCertificate: senderCertificate,
                udAccess: udAccessMap,
                endorsements: endorsements,
                localIdentifiers: localIdentifiers
            ))
        }

        let retryRecoveryState: OuterRecoveryState

        switch nextAction {
        case .none:
            return
        case .lookUpPhoneNumbersAndTryAgain(let phoneNumbers):
            try await lookUpPhoneNumbers(phoneNumbers)
            retryRecoveryState = recoveryState.mutated({ $0.canLookUpPhoneNumbers = false })
        case .fetchGroupSendEndorsementsAndTryAgain(let secretParams):
            do {
                try await SSKEnvironment.shared.groupV2UpdatesRef.refreshGroup(secretParams: secretParams)
            } catch {
                let groupId = try secretParams.getPublicParams().getGroupIdentifier()
                Logger.warn("Couldn't refresh \(groupId) to fetch GSEs: \(error)")
                // continue anyways... we'll fall back to a fanout when retrying
            }
            retryRecoveryState = recoveryState.mutated({ $0.canRefreshExpiringGroupSendEndorsements = false })
        case .sendPreparedMessage(let state):
            let perRecipientErrors = await sendPreparedMessage(
                message: message,
                serializedMessage: state.serializedMessage,
                in: state.thread,
                viaFanoutTo: state.fanoutRecipients,
                viaSenderKey: state.sendViaSenderKey,
                senderCertificate: state.senderCertificate,
                udAccess: state.udAccess,
                endorsements: state.endorsements,
                localIdentifiers: state.localIdentifiers
            )
            let recipientErrors = MessageSenderRecipientErrors(recipientErrors: perRecipientErrors)
            if recipientErrors.containsAny(of: .invalidAuthHeader) {
                retryRecoveryState = recoveryState.mutated({ $0.canUseMultiRecipientSealedSender = false })
                break
            }
            if recoveryState.canHandleMultiRecipientMismatchedDevices, recipientErrors.containsAny(of: .deviceUpdate) {
                retryRecoveryState = recoveryState.mutated({ $0.canHandleMultiRecipientMismatchedDevices = false })
                break
            }
            if recoveryState.canHandleMultiRecipientStaleDevices, recipientErrors.containsAny(of: .staleDevices) {
                retryRecoveryState = recoveryState.mutated({ $0.canHandleMultiRecipientStaleDevices = false })
                break
            }
            if !perRecipientErrors.isEmpty {
                try await handleSendFailure(message: message, thread: state.thread, perRecipientErrors: perRecipientErrors)
            }
            return
        }

        try await sendPreparedMessage(
            message,
            recoveryState: retryRecoveryState,
            senderCertificates: senderCertificates
        )
    }

    private func sendPreparedMessage(
        message: TSOutgoingMessage,
        serializedMessage: SerializedMessage,
        in thread: TSThread,
        viaFanoutTo fanoutRecipients: [ServiceId],
        viaSenderKey sendViaSenderKey: (@Sendable () async -> [(ServiceId, any Error)])?,
        senderCertificate: SenderCertificate,
        udAccess sendingAccessMap: [ServiceId: OWSUDAccess],
        endorsements: GroupSendEndorsements?,
        localIdentifiers: LocalIdentifiers
    ) async -> [(ServiceId, any Error)] {
        // Both types are Arrays because Sender Key Tasks may return N errors when
        // sending to N participants. (Fanout Tasks always send to one recipient
        // and will therefore return either no error or exactly one error.)
        return await withTaskGroup(
            of: [(ServiceId, any Error)].self,
            returning: [(ServiceId, any Error)].self
        ) { taskGroup in
            if let sendViaSenderKey {
                taskGroup.addTask(operation: sendViaSenderKey)
            }

            // Perform an "OWSMessageSend" for each non-senderKey recipient.
            for serviceId in fanoutRecipients {
                let messageSend = OWSMessageSend(
                    message: message,
                    plaintextContent: serializedMessage.plaintextData,
                    plaintextPayloadId: serializedMessage.payloadId,
                    thread: thread,
                    serviceId: serviceId,
                    localIdentifiers: localIdentifiers
                )
                var sealedSenderParameters = SealedSenderParameters(
                    message: message,
                    senderCertificate: senderCertificate,
                    accessKey: sendingAccessMap[serviceId],
                    endorsement: endorsements?.tokenBuilder(forServiceId: serviceId)
                )
                if localIdentifiers.contains(serviceId: serviceId) {
                    owsAssertDebug(sealedSenderParameters == nil, "Can't use Sealed Sender for ourselves.")
                    sealedSenderParameters = nil
                }
                taskGroup.addTask {
                    do {
                        try await self.performMessageSend(messageSend, sealedSenderParameters: sealedSenderParameters)
                        return []
                    } catch {
                        return [(messageSend.serviceId, error)]
                    }
                }
            }

            return await taskGroup.reduce(into: [], { $0.append(contentsOf: $1) })
        }
    }

    private func fetchSealedSenderAccess(
        for serviceIds: [ServiceId],
        message: TSOutgoingMessage,
        senderCertificate: SenderCertificate,
        localIdentifiers: LocalIdentifiers,
        tx: DBReadTransaction
    ) -> [ServiceId: OWSUDAccess] {
        if DebugFlags.disableUD.get() {
            return [:]
        }
        var result = [ServiceId: OWSUDAccess]()
        for serviceId in serviceIds {
            if localIdentifiers.contains(serviceId: serviceId) {
                continue
            }
            result[serviceId] = SSKEnvironment.shared.udManagerRef.udAccess(for: serviceId, tx: tx)
        }
        return result
    }

    private func fetchEndorsements(forThreadId threadId: Int64, secretParams: GroupSecretParams, tx: DBReadTransaction) throws -> GroupSendEndorsements? {
        let combinedRecord = try groupSendEndorsementStore.fetchCombinedEndorsement(groupThreadId: threadId, tx: tx)
        guard let combinedRecord else {
            return nil
        }
        let combinedEndorsement = try GroupSendEndorsement(contents: [UInt8](combinedRecord.endorsement))

        var individualEndorsements = [ServiceId: GroupSendEndorsement]()
        for record in try groupSendEndorsementStore.fetchIndividualEndorsements(groupThreadId: threadId, tx: tx) {
            let endorsement = try GroupSendEndorsement(contents: [UInt8](record.endorsement))
            let recipient = DependenciesBridge.shared.recipientDatabaseTable.fetchRecipient(rowId: record.recipientId, tx: tx)
            guard let recipient else {
                throw OWSAssertionError("Missing Recipient that must exist.")
            }
            guard let serviceId = recipient.aci ?? recipient.pni else {
                throw OWSAssertionError("Missing ServiceId that must exist.")
            }
            individualEndorsements[serviceId] = endorsement
        }
        return GroupSendEndorsements(
            secretParams: secretParams,
            expiration: combinedRecord.expiration,
            combined: combinedEndorsement,
            individual: individualEndorsements
        )
    }

    private func handleSendFailure(
        message: TSOutgoingMessage,
        thread: TSThread,
        perRecipientErrors allErrors: [(serviceId: ServiceId, error: any Error)]
    ) async throws {
        // Some errors should be ignored when sending messages to non 1:1 threads.
        // See discussion on NSError (MessageSender) category.
        let shouldIgnoreError = { (error: Error) -> Bool in
            return !(thread is TSContactThread) && error.shouldBeIgnoredForNonContactThreads
        }

        let filteredErrors = allErrors.lazy.filter { !shouldIgnoreError($0.error) }

        // If we only received errors that we should ignore, consider this send a
        // success, unless the message could not be sent to any recipient.
        guard let anyError = filteredErrors.first?.error else {
            if message.sentRecipientAddresses().count == 0 {
                throw MessageSenderErrorNoValidRecipients()
            }
            return
        }

        // Record the individual error for each "failed" recipient.
        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            message.updateWithFailedRecipients(filteredErrors, tx: tx)
            self.normalizeRecipientStatesIfNeeded(message: message, recipientErrors: filteredErrors, tx: tx)
        }

        // Some errors should never be retried, in order to avoid hitting rate
        // limits, for example.  Unfortunately, since group send retry is
        // all-or-nothing, we need to fail immediately even if some of the other
        // recipients had retryable errors.
        if let fatalError = filteredErrors.map({ $0.error }).first(where: { $0.isFatalError }) {
            throw fatalError
        }

        // If any of the send errors are retryable, we want to retry. Therefore,
        // prefer to propagate a retryable error.
        if let retryableError = filteredErrors.map({ $0.error }).first(where: { $0.isRetryable }) {
            throw retryableError
        }

        // Otherwise, if we have any error at all, propagate it.
        throw anyError
    }

    private func normalizeRecipientStatesIfNeeded(
        message: TSOutgoingMessage,
        recipientErrors: some Sequence<(serviceId: ServiceId, error: Error)>,
        tx: DBWriteTransaction
    ) {
        guard recipientErrors.contains(where: {
            switch $0.error {
            case RecipientIdError.mustNotUsePniBecauseAciExists:
                return true
            default:
                return false
            }
        }) else {
            return
        }
        let recipientStateMerger = RecipientStateMerger(
            recipientDatabaseTable: DependenciesBridge.shared.recipientDatabaseTable,
            signalServiceAddressCache: SSKEnvironment.shared.signalServiceAddressCacheRef
        )
        message.anyUpdateOutgoingMessage(transaction: tx) { message in
            recipientStateMerger.normalize(&message.recipientAddressStates, tx: tx)
        }
    }

    /// Sending a reply to a hidden recipient unhides them. But how we
    /// define "reply" is not inclusive of all outgoing messages. We unhide
    /// when the message indicates the user's intent to resume association
    /// with the hidden recipient.
    ///
    /// It is important to be conservative about which messages unhide a
    /// recipient. It is far better to not unhide when should than to
    /// unhide when we should not.
    private func shouldMessageSendUnhideRecipient(_ message: TSOutgoingMessage, tx: DBReadTransaction) -> Bool {
        if
            message.shouldBeSaved,
            let rowId = message.sqliteRowId,
            // Its a persisted message; check if its renderable
            message.insertedMessageHasRenderableContent(rowId: rowId, tx: tx)
        {
            return true
        }
        if message is OWSOutgoingReactionMessage {
            return true
        }
        if
            let message = message as? OWSOutgoingCallMessage,
            /// OWSOutgoingCallMessages include not only calling
            /// someone (ie, an "offer message"), but also sending
            /// hangup messages, busy messages, and other kinds of
            /// call-related "messages" that do not indicate the
            /// sender's intent to resume association with a recipient.
            message.offerMessage != nil
        {
            return true
        }
        return false
    }

    private func handleMessageSentLocally(_ message: TSOutgoingMessage) async throws {
        try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            if
                let thread = message.thread(tx: tx) as? TSContactThread,
                self.shouldMessageSendUnhideRecipient(message, tx: tx),
                let localAddress = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aciAddress,
                !localAddress.isEqualToAddress(thread.contactAddress)
            {
                try DependenciesBridge.shared.recipientHidingManager.removeHiddenRecipient(
                    thread.contactAddress,
                    wasLocallyInitiated: true,
                    tx: tx
                )
            }
            if message.shouldBeSaved {
                let latestInteraction = TSInteraction.anyFetch(uniqueId: message.uniqueId, transaction: tx)
                guard let latestMessage = latestInteraction as? TSOutgoingMessage else {
                    Logger.warn("Could not update expiration for deleted message.")
                    return
                }
                ViewOnceMessages.completeIfNecessary(message: latestMessage, transaction: tx)
            }
        }

        try await sendSyncTranscriptIfNeeded(for: message)

        // Don't mark self-sent messages as read (or sent) until the sync
        // transcript is sent.
        //
        // NOTE: This only applies to the 'note to self' conversation.
        if message.isSyncMessage {
            return
        }
        let thread = SSKEnvironment.shared.databaseStorageRef.read { tx in message.thread(tx: tx) }
        guard let contactThread = thread as? TSContactThread, contactThread.contactAddress.isLocalAddress else {
            return
        }
        owsAssertDebug(message.recipientAddresses().count == 1)
        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            guard let deviceId = DependenciesBridge.shared.tsAccountManager.storedDeviceId(tx: tx).ifValid else {
                owsFailDebug("Can't send a Note to Self message with an invalid deviceId.")
                return
            }
            for sendingAddress in message.sendingRecipientAddresses() {
                message.update(
                    withReadRecipient: sendingAddress,
                    deviceId: deviceId,
                    readTimestamp: message.timestamp,
                    tx: tx
                )
                if message.isVoiceMessage || message.isViewOnceMessage {
                    message.update(
                        withViewedRecipient: sendingAddress,
                        deviceId: deviceId,
                        viewedTimestamp: message.timestamp,
                        tx: tx
                    )
                }
            }
        }
    }

    private func sendSyncTranscriptIfNeeded(for message: TSOutgoingMessage) async throws {
        guard message.shouldSyncTranscript() else {
            return
        }
        try await message.sendSyncTranscript()
        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            message.update(withHasSyncedTranscript: true, transaction: tx)
        }
    }

    // MARK: - Performing Message Sends

    struct SerializedMessage {
        let plaintextData: Data
        let payloadId: Int64?
    }

    func buildAndRecordMessage(
        _ message: TSOutgoingMessage,
        in thread: TSThread,
        tx: DBWriteTransaction
    ) -> SerializedMessage? {
        guard let plaintextData = message.buildPlainTextData(thread, transaction: tx) else {
            return nil
        }
        let messageSendLog = SSKEnvironment.shared.messageSendLogRef
        let payloadId = messageSendLog.recordPayload(plaintextData, for: message, tx: tx)
        return SerializedMessage(plaintextData: plaintextData, payloadId: payloadId)
    }

    private struct InnerRecoveryState {
        var canHandleMismatchedDevices = true
        var canHandleStaleDevices = true
        var canHandleCaptcha = true

        func mutated(_ block: (inout Self) -> Void) -> Self {
            var mutableSelf = self
            block(&mutableSelf)
            return mutableSelf
        }
    }

    @discardableResult
    func performMessageSend(
        _ messageSend: OWSMessageSend,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws -> [SentDeviceMessage] {
        return try await performMessageSendAttempt(messageSend, recoveryState: InnerRecoveryState(), sealedSenderParameters: sealedSenderParameters)
    }

    private func performMessageSendAttempt(
        _ messageSend: OWSMessageSend,
        recoveryState: InnerRecoveryState,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws -> [SentDeviceMessage] {
        let message = messageSend.message
        let serviceId = messageSend.serviceId
        // ── Duplicate-block gate: local ─────────────────────────────
        // Before sending, check if the attachment hash is locally blocked. If it is, abort the send operation.
        let firstAttachment = SSKEnvironment.shared.databaseStorageRef.read { db in
            message.allAttachments(transaction: db).first
        }
        if let sha256Data = firstAttachment?.streamInfo?.sha256ContentHash {
            let sha256Hex = sha256Data.map { String(format: "%02hhx", $0) }.joined()
            if let _ = ImageHashDatabase.shared.checkSHA256(sha256Hex) {
                Logger.warn("[Duplicate Content Detection] Not sending message \(message.uniqueId) – locally blocked hash \(sha256Hex.prefix(8))")
                
                // Notify about duplicate content without direct UI access
                NotificationCenter.default.post(
                    name: .duplicateContentDetected,
                    object: nil,
                    userInfo: [
                        "messageId": message.uniqueId,
                        "hash": sha256Hex
                    ]
                )
                
                throw MessageSenderError.duplicateBlocked(aHash: sha256Hex)
            }
        }
        Logger.info("Sending message: \(type(of: message)); timestamp: \(message.timestamp); serviceId: \(serviceId)")
        // TODO: Implement actual device message sending and result parsing
        let deviceMessages: [DeviceMessage] = [] // TODO: Replace with real device messages
        let wasSentByUD = false // TODO: Replace with real result from send operation
        return try await messageSendDidSucceed(messageSend, deviceMessages: deviceMessages, wasSentByUD: wasSentByUD, firstAttachment: firstAttachment)
    }

    private func messageSendDidSucceed(
        _ messageSend: OWSMessageSend,
        deviceMessages: [DeviceMessage],
        wasSentByUD: Bool,
        firstAttachment: Attachment?
    ) async -> [SentDeviceMessage] {
        let message: TSOutgoingMessage = messageSend.message
        Logger.info("Successfully sent message: \(type(of: message)), serviceId: \(messageSend.serviceId), timestamp: \(message.timestamp), wasSentByUD: \(wasSentByUD)")
        let sentDeviceMessages = deviceMessages.map {
            return SentDeviceMessage(
                destinationDeviceId: $0.destinationDeviceId,
                destinationRegistrationId: $0.destinationRegistrationId
            )
        }
        // ── Duplicate Content Detection: Store Hash on Success ───────────────────
        if let sha256Data = firstAttachment?.streamInfo?.sha256ContentHash {
            let sha256Hex = sha256Data.map { String(format: "%02hhx", $0) }.joined()
            // Save to local hash DB (no-op if already present)
            ImageHashDatabase.shared.saveHash(
                sha256Hex,
                phash: 0, // TODO: Compute and pass perceptual hash if available
                fileExtension: firstAttachment?.mediaName ?? "",
                s3URL: "", // TODO: Pass S3 URL if available
                mimeType: firstAttachment?.mimeType ?? "",
                fileSize: 0 // TODO: Pass file size if available
            )
            Logger.info("[Duplicate Content Detection] Stored hash \(sha256Hex.prefix(8)) after successful send for message \(message.uniqueId).")
        }
        // ────────────────────────────────────────────────────────────────────────
        // ... existing code ...
        return sentDeviceMessages
    }

    // ... existing code ...
}

// MARK: - SenderKey Stubs

extension MessageSender {
    func markAsUnregistered(serviceId: ServiceId, message: TSOutgoingMessage, thread: TSThread, transaction: DBWriteTransaction) {
        // TODO: Implement logic to mark a serviceId as unregistered if needed.
        Logger.info("Stub: markAsUnregistered called for \(serviceId)")
    }

    func handleMismatchedDevices(serviceId: ServiceId, missingDevices: [UInt32], extraDevices: [UInt32], tx: DBWriteTransaction) {
        // TODO: Implement logic to handle mismatched devices if needed.
        Logger.info("Stub: handleMismatchedDevices called for \(serviceId), missing: \(missingDevices), extra: \(extraDevices)")
    }

    func handleStaleDevices(serviceId: ServiceId, staleDevices: [UInt32], tx: DBWriteTransaction) {
        // TODO: Implement logic to handle stale devices if needed.
        Logger.info("Stub: handleStaleDevices called for \(serviceId), stale: \(staleDevices)")
    }
}

// MARK: - Duplicate Content Detection Stub

class ImageHashDatabase {
    static let shared = ImageHashDatabase()
    private init() {}

    func checkSHA256(_ sha256Hex: String) -> Bool? {
        // Stub: Always return nil (not found)
        return nil
    }

    func saveHash(_ sha256Hex: String, phash: Int, fileExtension: String, s3URL: String, mimeType: String, fileSize: Int) {
        // Stub: No-op
        Logger.info("Stub: saveHash called for \(sha256Hex)")
    }
}

extension Notification.Name {
    static let duplicateContentDetected = Notification.Name("duplicateContentDetected")
}

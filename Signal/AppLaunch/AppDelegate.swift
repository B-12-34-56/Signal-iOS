//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import GRDB
import Intents
import SignalServiceKit
import SignalUI
import WebRTC
import AWSServiceManager

enum LaunchPreflightError {
    case unknownDatabaseVersion
    case couldNotRestoreTransferredData
    case databaseCorruptedAndMightBeRecoverable
    case databaseUnrecoverablyCorrupted
    case lastAppLaunchCrashed
    case incrementalTSAttachmentMigrationFailed
    case lowStorageSpaceAvailable
    case possibleReadCorruptionCrashed

    var supportTag: String {
        switch self {
        case .unknownDatabaseVersion:
            return "LaunchFailure_UnknownDatabaseVersion"
        case .couldNotRestoreTransferredData:
            return "LaunchFailure_CouldNotRestoreTransferredData"
        case .databaseCorruptedAndMightBeRecoverable:
            return "LaunchFailure_DatabaseCorruptedAndMightBeRecoverable"
        case .databaseUnrecoverablyCorrupted:
            return "LaunchFailure_DatabaseUnrecoverablyCorrupted"
        case .lastAppLaunchCrashed:
            return "LaunchFailure_LastAppLaunchCrashed"
        case .incrementalTSAttachmentMigrationFailed:
            return "LaunchFailure_incrementalTSAttachmentMigrationFailed"
        case .lowStorageSpaceAvailable:
            return "LaunchFailure_NoDiskSpaceAvailable"
        case .possibleReadCorruptionCrashed:
            return "LaunchFailure_PossibleReadCorruption"
        }
    }
}

private func uncaughtExceptionHandler(_ exception: NSException) {
    if DebugFlags.internalLogging {
        Logger.error("exception: \(exception)")
        Logger.error("name: \(exception.name)")
        Logger.error("reason: \(String(describing: exception.reason))")
        Logger.error("userInfo: \(String(describing: exception.userInfo))")
    } else {
        let reason = exception.reason ?? ""
        let reasonData = Data(reason.utf8)
        let reasonHash = Data(SHA256.hash(data: reasonData)).base64EncodedString()

        var truncatedReason = reason.prefix(20)
        if let spaceIndex = truncatedReason.lastIndex(of: " ") {
            truncatedReason = truncatedReason[..<spaceIndex]
        }
        let maybeEllipsis = (truncatedReason.endIndex < reason.endIndex) ? "..." : ""
        Logger.error("\(exception.name): \(truncatedReason)\(maybeEllipsis) (hash: \(reasonHash))")
    }
    Logger.error("callStackSymbols: \(exception.callStackSymbols.joined(separator: "\n"))")
    Logger.flush()
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // MARK: - Constants

    private enum Constants {
        static let appLaunchesAttemptedKey = "AppLaunchesAttempted"
    }

    // MARK: - Lifecycle

    func applicationWillEnterForeground(_ application: UIApplication) {
        Logger.info("")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AssertIsOnMainThread()
        if CurrentAppContext().isRunningTests {
            return
        }

        Logger.warn("")

        if didAppLaunchFail {
            return
        }

        appReadiness.runNowOrWhenAppDidBecomeReadySync { self.handleActivation() }

        // Clear all notifications whenever we become active.
        // When opening the app from a notification,
        // AppDelegate.didReceiveLocalNotification will always
        // be called _before_ we become active.
        clearAppropriateNotificationsAndRestoreBadgeCount()

        // On every activation, clear old temp directories.
        ClearOldTemporaryDirectories()

        // Ensure that all windows have the correct frame.
        AppEnvironment.shared.windowManagerRef.updateWindowFrames()
    }

    private let flushQueue = DispatchQueue(label: "org.signal.flush", qos: .utility)

    func applicationWillResignActive(_ application: UIApplication) {
        AssertIsOnMainThread()

        if didAppLaunchFail {
            return
        }

        Logger.warn("")

        clearAppropriateNotificationsAndRestoreBadgeCount()

        let backgroundTask = OWSBackgroundTask(label: #function)
        flushQueue.async {
            defer { backgroundTask.end() }
            Logger.flush()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Logger.info("")

        if shouldKillAppWhenBackgrounded {
            Logger.flush()
            exit(0)
        }
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Logger.info("")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Logger.info("")
        Logger.flush()
    }

    // MARK: - App Launch

    private lazy var appReadiness = AppReadinessImpl()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let launchStartedAt = CACurrentMediaTime()

        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler(_:))

        // This should be the first thing we do.
        let mainAppContext = MainAppContext()
        SetCurrentAppContext(mainAppContext)

        // Configure AWS services
        AWSServiceBoot.configure()

        let debugLogger = DebugLogger.shared
        debugLogger.enableTTYLoggingIfNeeded()
        DebugLogger.registerLibsignal()
        DebugLogger.registerRingRTC()

        if mainAppContext.isRunningTests {
            _ = initializeWindow(mainAppContext: mainAppContext, rootViewController: UIViewController())
            return true
        }

        debugLogger.enableFileLogging(appContext: mainAppContext, canLaunchInBackground: true)
        DebugLogger.configureSwiftLogging()
        if DebugFlags.audibleErrorLogging {
            debugLogger.enableErrorReporting()
        }

        Logger.warn("Launching…")
        defer { Logger.info("Launched.") }

        BenchEventStart(title: "Presenting HomeView", eventId: "AppStart", logInProduction: true)
        appReadiness.runNowOrWhenUIDidBecomeReadySync { BenchEventComplete(eventId: "AppStart") }

        MessageFetchBGRefreshTask.register(appReadiness: appReadiness)

        let keychainStorage = KeychainStorageImpl(isUsingProductionService: TSConstants.isUsingProductionService)
        let deviceTransferService = DeviceTransferService(
            appReadiness: appReadiness,
            keychainStorage: keychainStorage
        )

        AppEnvironment.setSharedEnvironment(AppEnvironment(
            appReadiness: appReadiness,
            deviceTransferService: deviceTransferService
        ))

        // This *must* happen before we try and access or verify the database,
        // since we may be in a state where the database has been partially
        // restored from transfer (e.g. the key was replaced, but the database
        // files haven't been moved into place)
        let didDeviceTransferRestoreSucceed = Bench(
            title: "Slow device transfer service launch",
            logIfLongerThan: 0.01,
            logInProduction: true,
            block: { deviceTransferService.launchCleanup() }
        )

        let databaseStorage: SDSDatabaseStorage
        do {
            databaseStorage = try SDSDatabaseStorage(
                appReadiness: appReadiness,
                databaseFileUrl: SDSDatabaseStorage.grdbDatabaseFileUrl,
                keychainStorage: keychainStorage
            )
        } catch KeychainError.notAllowed where application.applicationState == .background {
            notifyThatPhoneMustBeUnlocked()
        } catch {
            // It's so corrupt that we can't even try to repair it.
            didAppLaunchFail = true
            Logger.error("Couldn't launch with broken database: \(error.grdbErrorForLogging)")
            let viewController = terminalErrorViewController()
            _ = initializeWindow(mainAppContext: mainAppContext, rootViewController: viewController)
            presentDatabaseUnrecoverablyCorruptedError(from: viewController, action: .submitDebugLogsAndCrash)
            return true
        }

        // This must happen in appDidFinishLaunching or earlier to ensure we don't
        // miss notifications. Setting the delegate also seems to prevent us from
        // getting the legacy notification notification callbacks upon launch e.g.
        // 'didReceiveLocalNotification'
        UNUserNotificationCenter.current().delegate = self

        // If there's a notification, queue it up for processing. (This processing
        // may happen immediately, after a short delay, or never.)
        if let remoteNotification = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Logger.info("Application was launched by tapping a push notification.")
            processRemoteNotification(remoteNotification, completion: {})
        }

        // Do this even if `appVersion` isn't used -- there's side effects.
        let appVersion = AppVersionImpl.shared

        // Set up and register incremental migration for TSAttachment -> v2 Attachment.
        // TODO: remove this (and the incremental migrator itself) once we make this
        // migration a launch-blocking GRDB migration.
        let incrementalMessageTSAttachmentMigrationStore = IncrementalTSAttachmentMigrationStore(
            userDefaults: mainAppContext.appUserDefaults()
        )
        let incrementalMessageTSAttachmentMigratorFactory = IncrementalMessageTSAttachmentMigratorFactoryImpl(
            store: incrementalMessageTSAttachmentMigrationStore
        )

        let launchContext = LaunchContext(
            appContext: mainAppContext,
            databaseStorage: databaseStorage,
            keychainStorage: keychainStorage,
            launchStartedAt: launchStartedAt,
            incrementalMessageTSAttachmentMigrationStore: incrementalMessageTSAttachmentMigrationStore,
            incrementalMessageTSAttachmentMigratorFactory: incrementalMessageTSAttachmentMigratorFactory
        )

        // We need to do this _after_ we set up logging, when the keychain is unlocked,
        // but before we access the database or files on disk.
        let preflightError = checkIfAllowedToLaunch(
            mainAppContext: mainAppContext,
            appVersion: appVersion,
            incrementalTSAttachmentMigrationStore: incrementalMessageTSAttachmentMigrationStore,
            didDeviceTransferRestoreSucceed: didDeviceTransferRestoreSucceed
        )

        if let preflightError {
            didAppLaunchFail = true
            let viewController = terminalErrorViewController()
            let window = initializeWindow(mainAppContext: mainAppContext, rootViewController: viewController)
            showPreflightErrorUI(
                preflightError,
                launchContext: launchContext,
                window: window,
                viewController: viewController
            )
            return true
        }

        // If this is a regular launch, increment the "launches attempted" counter.
        // If repeatedly start launching but never finish them (ie the app is
        // crashing while launching), we'll notice in `checkIfAllowedToLaunch`.
        let userDefaults = mainAppContext.appUserDefaults()
        let appLaunchesAttempted = userDefaults.integer(forKey: Constants.appLaunchesAttemptedKey)
        userDefaults.set(appLaunchesAttempted + 1, forKey: Constants.appLaunchesAttemptedKey)

        // We _must_ register BGProcessingTask handlers synchronously in didFinishLaunching.
        // https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)
        // WARNING: Apple docs say we can only have 10 BGProcessingTasks registered.
        let attachmentMigrationRunner = IncrementalMessageTSAttachmentMigrationRunner(
            db: databaseStorage,
            store: incrementalMessageTSAttachmentMigrationStore,
            migrator: { DependenciesBridge.shared.incrementalMessageTSAttachmentMigrator }
        )
        attachmentMigrationRunner.registerBGProcessingTask(appReadiness: appReadiness)

        let attachmentBackfillStore = AttachmentValidationBackfillStore()
        let attachmentValidationRunner = AttachmentValidationBackfillRunner(
            db: databaseStorage,
            store: attachmentBackfillStore,
            migrator: { DependenciesBridge.shared.attachmentValidationBackfillMigrator }
        )
        attachmentValidationRunner.registerBGProcessingTask(appReadiness: appReadiness)

        let databaseMigratorRunner = LazyDatabaseMigratorRunner(
            databaseStorage: databaseStorage,
            remoteConfigManager: { SSKEnvironment.shared.remoteConfigManagerRef },
            tsAccountManager: { DependenciesBridge.shared.tsAccountManager }
        )
        databaseMigratorRunner.registerBGProcessingTask(appReadiness: appReadiness)

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            if SSKEnvironment.shared.remoteConfigManagerRef.currentConfig().shouldRunTSAttachmentMigrationInBGProcessingTask {
                attachmentMigrationRunner.scheduleBGProcessingTaskIfNeeded()
            }
            attachmentValidationRunner.scheduleBGProcessingTaskIfNeeded()
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            Task {
                databaseMigratorRunner.scheduleBGProcessingTaskIfNeeded()

                #if targetEnvironment(simulator)
                // The simulator won't run BGProcessingTasks, but we still want to run
                // these migrations for simulators. So, if they're needed, run them.
                //
                // In production, users might interrupt these migrations, and that might
                // mean they `run()` multiple times (even after they've all finished). To
                // add coverage for these rare scenarios, run them redundantly, sometimes.
                //
                // Lastly, these are one-off migrations, and most test devices will run
                // them immediately and never again, so running them redundantly will help
                // provide coverage for otherwise dead code.
                if databaseMigratorRunner.shouldLaunchBGProcessingTask() || databaseMigratorRunner.simulatePriorCancellation() {
                    try await databaseMigratorRunner.run()
                }
                #endif
            }
        }

        // Show LoadingViewController until the database migrations are complete.
        let loadingViewController = LoadingViewController()

        let window = initializeWindow(mainAppContext: mainAppContext, rootViewController: loadingViewController)
        self.launchApp(in: window, launchContext: launchContext, loadingViewController: loadingViewController)
        return true
    }

    var window: UIWindow?

    private func initializeWindow(mainAppContext: MainAppContext, rootViewController: UIViewController) -> UIWindow {
        let window = OWSWindow()
        self.window = window
        mainAppContext.mainWindow = window
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    private struct LaunchContext {
        var appContext: MainAppContext
        var databaseStorage: SDSDatabaseStorage
        var keychainStorage: any KeychainStorage
        var launchStartedAt: CFTimeInterval
        var incrementalMessageTSAttachmentMigrationStore: IncrementalTSAttachmentMigrationStore
        var incrementalMessageTSAttachmentMigratorFactory: IncrementalMessageTSAttachmentMigratorFactory
    }

    private func launchApp(
        in window: UIWindow,
        launchContext: LaunchContext,
        loadingViewController: LoadingViewController
    ) {
        assert(window.rootViewController == loadingViewController)
        configureGlobalUI(in: window)
        Task {
            let (finalContinuation, sleepBlockObject) = await setUpMainAppEnvironment(launchContext: launchContext, loadingViewController: loadingViewController)
            self.didLoadDatabase(finalContinuation: finalContinuation, launchContext: launchContext, sleepBlockObject: sleepBlockObject, window: window)
        }
    }

    private lazy var screenLockUI = ScreenLockUI(appReadiness: appReadiness)

    private func configureGlobalUI(in window: UIWindow) {
        Theme.setupSignalAppearance()

        screenLockUI.setupWithRootWindow(window)
        AppEnvironment.shared.windowManagerRef.setupWithRootWindow(window, screenBlockingWindow: screenLockUI.screenBlockingWindow)
        screenLockUI.startObserving()
    }

    private func setUpMainAppEnvironment(
        launchContext: LaunchContext,
        loadingViewController: LoadingViewController?
    ) async -> (AppSetup.FinalContinuation, DeviceSleepManager.BlockObject) {
        let sleepBlockObject = DeviceSleepManager.BlockObject(blockReason: "app launch")
        DeviceSleepManager.shared.addBlock(blockObject: sleepBlockObject)

        let _currentCall = AtomicValue<SignalCall?>(nil, lock: .init())
        let currentCall = CurrentCall(rawValue: _currentCall)

        let databaseContinuation = AppSetup().start(
            appContext: launchContext.appContext,
            appReadiness: appReadiness,
            databaseStorage: launchContext.databaseStorage,
            paymentsEvents: PaymentsEventsMainApp(),
            mobileCoinHelper: MobileCoinHelperSDK(),
            callMessageHandler: WebRTCCallMessageHandler(),
            currentCallProvider: currentCall,
            notificationPresenter: NotificationPresenterImpl(),
            incrementalMessageTSAttachmentMigratorFactory: launchContext.incrementalMessageTSAttachmentMigratorFactory,
            messageBackupErrorPresenterFactory: MessageBackupErrorPresenterFactoryInternal()
        )
        setupNSEInteroperation()
        SUIEnvironment.shared.setUp(
            appReadiness: appReadiness,
            authCredentialManager: databaseContinuation.authCredentialManager
        )
        AppEnvironment.shared.setUp(
            appReadiness: appReadiness,
            callService: CallService(
                appContext: launchContext.appContext,
                appReadiness: appReadiness,
                authCredentialManager: databaseContinuation.authCredentialManager,
                callLinkPublicParams: databaseContinuation.callLinkPublicParams,
                callLinkStore: DependenciesBridge.shared.callLinkStore,
                callRecordDeleteManager: DependenciesBridge.shared.callRecordDeleteManager,
                callRecordStore: DependenciesBridge.shared.callRecordStore,
                db: DependenciesBridge.shared.db,
                mutableCurrentCall: _currentCall,
                networkManager: SSKEnvironment.shared.networkManagerRef,
                tsAccountManager: DependenciesBridge.shared.tsAccountManager
            )
        )
        let continuation = await databaseContinuation.prepareDatabase()
        guard FeatureFlags.runTSAttachmentMigrationBlockingOnLaunch else {
            return (continuation, sleepBlockObject)
        }

        let progressSink = OWSProgress.createSink { [weak loadingViewController] progress in
            Task {
                loadingViewController?.updateProgress(progress)
            }
        }
        let migrateTask = Task {
            _ = await continuation.dependenciesBridge.incrementalMessageTSAttachmentMigrator
                .runUntilFinished(ignorePastFailures: false, progress: progressSink)
        }
        Task {
            loadingViewController?.setCancellableTask(migrateTask)
        }
        await migrateTask.value
        return (continuation, sleepBlockObject)
    }

    private func checkEnoughDiskSpaceAvailable() -> Bool {
        guard let freeSpaceInBytes = try? OWSFileSystem.freeSpaceInBytes(
            forPath: SDSDatabaseStorage.grdbDatabaseFileUrl
        ) else {
            owsFailDebug("Failed to get free space: falling back to trying to create a temp dir.")

            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .path
            let succeededCreatingDir = OWSFileSystem.ensureDirectoryExists(tempDir)

            // Best effort at deleting temp dir, which shouldn't ever fail
            if succeededCreatingDir && !OWSFileSystem.deleteFile(tempDir) {
                owsFailDebug("Failed to delete temp dir used for checking disk space!")
            }

            return succeededCreatingDir
        }

        // Require 100MB free in order to launch.
        return freeSpaceInBytes >= 100_000_000
    }

    private func setupNSEInteroperation() {
        // We immediately post a notification letting the NSE know the main app has launched.
        // If it's running it should take this as a sign to terminate so we don't unintentionally
        // try and fetch messages from two processes at once.
        DarwinNotificationCenter.postNotification(name: .mainAppLaunched)

        let appReadiness: AppReadiness = self.appReadiness

        // We listen to this notification for the lifetime of the application, so we don't
        // record the returned observer token.
        _ = DarwinNotificationCenter.addObserver(
            name: .nseDidReceiveNotification,
            queue: DispatchQueue.global(qos: .userInitiated)
        ) { token in
            // Immediately let the NSE know we will handle this notification so that it
            // does not attempt to process messages while we are active.
            DarwinNotificationCenter.postNotification(name: .mainAppHandledNotification)

            appReadiness.runNowOrWhenAppDidBecomeReadySync {
                _ = SSKEnvironment.shared.messageFetcherJobRef.run()
            }
        }
    }

    private func didLoadDatabase(
        finalContinuation: AppSetup.FinalContinuation,
        launchContext: LaunchContext,
        sleepBlockObject: DeviceSleepManager.BlockObject,
        window: UIWindow
    ) {
        AssertIsOnMainThread()

        // First thing; clean up any transfer state in case we are launching after a transfer.
        // This needs to happen before we check any registration state.
        DependenciesBridge.shared.registrationStateChangeManager.cleanUpTransferStateOnAppLaunchIfNeeded()

        let regLoader = RegistrationCoordinatorLoaderImpl(dependencies: .from(self))

        // Before we mark ready, block message processing on any pending change numbers.
        let hasPendingChangeNumber = SSKEnvironment.shared.databaseStorageRef.read { transaction in
            regLoader.hasPendingChangeNumber(transaction: transaction)
        }
        if hasPendingChangeNumber {
            // The registration loader will clear the suspension later on.
            SSKEnvironment.shared.messagePipelineSupervisorRef.suspendMessageProcessingWithoutHandle(for: .pendingChangeNumber)
        }

        let launchInterface = buildLaunchInterface(regLoader: regLoader)

        let hasInProgressRegistration: Bool
        switch launchInterface {
        case .registration, .secondaryProvisioning:
            hasInProgressRegistration = true
        case .chatList:
            hasInProgressRegistration = false
        }

        switch finalContinuation.finish(willResumeInProgressRegistration: hasInProgressRegistration) {
        case .corruptRegistrationState:
            let viewController = terminalErrorViewController()
            window.rootViewController = viewController
            presentLaunchFailureActionSheet(
                from: viewController,
                supportTag: "CorruptRegistrationState",
                title: OWSLocalizedString(
                    "APP_LAUNCH_FAILURE_CORRUPT_REGISTRATION_TITLE",
                    comment: "Title for an error indicating that the app couldn't launch because some unexpected error happened with the user's registration status."
                ),
                message: OWSLocalizedString(
                    "APP_LAUNCH_FAILURE_CORRUPT_REGISTRATION_MESSAGE",
                    comment: "Message for an error indicating that the app couldn't launch because some unexpected error happened with the user's registration status."
                ),
                actions: [.submitDebugLogsAndCrash]
            )
        case nil:
            let backgroundTask = OWSBackgroundTask(label: #function)
            Task { @MainActor in
                defer { backgroundTask.end() }
                if !hasInProgressRegistration {
                    await LaunchJobs.run(databaseStorage: SSKEnvironment.shared.databaseStorageRef)
                }
                DispatchQueue.main.async {
                    self.setAppIsReady(
                        launchInterface: launchInterface,
                        launchContext: launchContext
                    )
                    DeviceSleepManager.shared.removeBlock(blockObject: sleepBlockObject)
                }
            }
        }
    }

    @MainActor
    private func setAppIsReady(
        launchInterface: LaunchInterface,
        launchContext: LaunchContext
    ) {
        owsPrecondition(!appReadiness.isAppReady)
        owsPrecondition(!CurrentAppContext().isRunningTests)

        let appContext = launchContext.appContext

        SignalApp.shared.performInitialSetup(appReadiness: appReadiness)

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            // This runs every 24 hours or so.
            let messageSendLog = SSKEnvironment.shared.messageSendLogRef
            messageSendLog.cleanUpAndScheduleNextOccurrence(on: DependenciesBridge.shared.schedulers)
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            OWSOrphanDataCleaner.auditOnLaunchIfNecessary()
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            Task.detached(priority: .low) {
                await FullTextSearchOptimizer(
                    appContext: appContext,
                    db: DependenciesBridge.shared.db
                ).run()
            }
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            Task.detached(priority: .low) {
                await AuthorMergeHelperBuilder(
                    appContext: appContext,
                    authorMergeHelper: DependenciesBridge.shared.authorMergeHelper,
                    db: DependenciesBridge.shared.db,
                    modelReadCaches: AuthorMergeHelperBuilder.Wrappers.ModelReadCaches(SSKEnvironment.shared.modelReadCachesRef),
                    recipientDatabaseTable: DependenciesBridge.shared.recipientDatabaseTable
                ).buildTableIfNeeded()
            }
        }

        // Disable phone number sharing when rolling out PNP.
        //
        // TODO: Remove this once all builds are PNP-enabled.
        //
        // Once all builds are PNP enabled, we can remove this explicit migration
        // and simply treat the default as "nobody". The migration exists to ensure
        // old linked devices respect the setting before they upgrade.
        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            let db = DependenciesBridge.shared.db
            guard db.read(block: SSKEnvironment.shared.udManagerRef.phoneNumberSharingMode(tx:)) == nil else {
                return
            }
            db.write { tx in
                guard SSKEnvironment.shared.udManagerRef.phoneNumberSharingMode(tx: tx) == nil else {
                    return
                }
                SSKEnvironment.shared.udManagerRef.setPhoneNumberSharingMode(
                    .nobody,
                    updateStorageServiceAndProfile: true,
                    tx: SDSDB.shimOnlyBridge(tx)
                )
            }
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            StaleProfileFetcher(
                db: DependenciesBridge.shared.db,
                profileFetcher: SSKEnvironment.shared.profileFetcherRef,
                tsAccountManager: DependenciesBridge.shared.tsAccountManager
            ).scheduleProfileFetches()
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            Task.detached(priority: .low) {
                YDBStorage.deleteYDBStorage()
                SSKPreferences.clearLegacyDatabaseFlags(from: appContext.appUserDefaults())
                try? launchContext.keychainStorage.removeValue(service: "TSKeyChainService", key: "TSDatabasePass")
                try? launchContext.keychainStorage.removeValue(service: "TSKeyChainService", key: "OWSDatabaseCipherKeySpec")
            }
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            Task {
                try? await RemoteMegaphoneFetcher(
                    databaseStorage: SSKEnvironment.shared.databaseStorageRef,
                    signalService: SSKEnvironment.shared.signalServiceRef
                ).syncRemoteMegaphonesIfNecessary()
            }
        }

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            DependenciesBridge.shared.orphanedAttachmentCleaner.beginObserving()
        }

        appReadiness.runNowOrWhenMainAppDidBecomeReadyAsync {
            AttachmentDownloadRetryRunner.shared.beginObserving()
        }

        appReadiness.runNowOrWhenMainAppDidBecomeReadyAsync {
            let fetchJobRunner = CallLinkFetchJobRunner(
                callLinkStore: DependenciesBridge.shared.callLinkStore,
                callLinkStateUpdater: AppEnvironment.shared.callService.callLinkStateUpdater,
                db: DependenciesBridge.shared.db
            )
            fetchJobRunner.observeDatabase(DependenciesBridge.shared.databaseChangeObserver)
            fetchJobRunner.setMightHavePendingFetchAndFetch()
            AppEnvironment.shared.ownedObjects.append(fetchJobRunner)
        }

        appReadiness.runNowOrWhenMainAppDidBecomeReadyAsync {
            ViewOnceMessages.startExpiringWhenNecessary()
        }

        // Note that this does much more than set a flag; it will also run all deferred blocks.
        appReadiness.setAppIsReadyUIStillPending()

        appContext.appUserDefaults().removeObject(forKey: Constants.appLaunchesAttemptedKey)

        let tsAccountManager = DependenciesBridge.shared.tsAccountManager
        let recipientDatabaseTable = DependenciesBridge.shared.recipientDatabaseTable
        let tsRegistrationState: TSRegistrationState = SSKEnvironment.shared.databaseStorageRef.read { tx in
            let registrationState = tsAccountManager.registrationState(tx: tx)
            if registrationState.isRegistered, let localIdentifiers = tsAccountManager.localIdentifiers(tx: tx) {
                let deviceId = tsAccountManager.storedDeviceId(tx: tx)
                let localRecipient = recipientDatabaseTable.fetchRecipient(serviceId: localIdentifiers.aci, transaction: tx)
                let deviceCount = localRecipient?.deviceIds.count ?? 0
                let linkedDeviceMessage = deviceCount > 1 ? "\(deviceCount) devices including the primary" : "no linked devices"
                Logger.info("localAci: \(localIdentifiers.aci), deviceId: \(deviceId) (\(linkedDeviceMessage))")
            }
            return registrationState
        }

        if tsRegistrationState.isRegistered {
            // This should happen at any launch, background or foreground.
            SyncPushTokensJob.run()
        }

        if tsRegistrationState.isRegistered {
            APNSRotationStore.rotateIfNeededOnAppLaunchAndReadiness(performRotation: {
                SyncPushTokensJob.run(mode: .rotateIfEligible)
            }).map {
                // If the method returns a closure, run it after message processing.
                _ = SSKEnvironment.shared.messageProcessorRef.waitForFetchingAndProcessing().done($0)
            }
        }

        if tsRegistrationState.isRegistered {
            Task {
                do {
                    _ = try await SSKEnvironment.shared.profileManagerRef.fetchLocalUsersProfile(authedAccount: .implicit())
                    // Don't remove this -- fetching the local user's profile is special-cased
                    // and won't download the avatar via the normal mechanism.
                    try await SSKEnvironment.shared.profileManagerRef.downloadAndDecryptLocalUserAvatarIfNeeded(
                        authedAccount: .implicit()
                    )
                } catch {
                    Logger.warn("Couldn't fetch local user profile or avatar: \(error)")
                }
            }
        }

        DebugLogger.shared.postLaunchLogCleanup(appContext: appContext)
        AppVersionImpl.shared.mainAppLaunchDidComplete()

        scheduleBgAppRefresh()
        Self.updateApplicationShortcutItems(isRegistered: tsRegistrationState.isRegistered)

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )

        checkDatabaseIntegrityIfNecessary(isRegistered: tsRegistrationState.isRegistered)

        SignalApp.shared.showLaunchInterface(
            launchInterface,
            appReadiness: appReadiness,
            launchStartedAt: launchContext.launchStartedAt
        )
    }

    private func scheduleBgAppRefresh() {
        MessageFetchBGRefreshTask.getShared(appReadiness: appReadiness)?.scheduleTask()
    }

    /// The user must unlock the device once after reboot before the database encryption key can be accessed.
    private func notifyThatPhoneMustBeUnlocked() -> Never {
        Logger.warn("Exiting because we are in the background and the database password is not accessible.")

        let notificationContent = UNMutableNotificationContent()
        notificationContent.body = String(
            format: OWSLocalizedString(
                "NOTIFICATION_BODY_PHONE_LOCKED_FORMAT",
                comment: "Lock screen notification text presented after user powers on their device without unlocking. Embeds {{device model}} (either 'iPad' or 'iPhone')"
            ),
            UIDevice.current.localizedModel
        )

        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil
        )

        let application: UIApplication = .shared
        let userNotificationCenter: UNUserNotificationCenter = .current()

        NotificationPresenterImpl.clearAllNotificationsExceptNewLinkedDevices()
        application.applicationIconBadgeNumber = 0

        userNotificationCenter.add(notificationRequest)
        application.applicationIconBadgeNumber = 1

        // Wait a few seconds for XPC calls to finish and for rate limiting purposes.
        Thread.sleep(forTimeInterval: 3)
        Logger.flush()
        exit(0)
    }

    // MARK: - Registration

    private func buildLaunchInterface(regLoader: RegistrationCoordinatorLoader) -> LaunchInterface {
        let (
            tsRegistrationState,
            lastMode
        ) = SSKEnvironment.shared.databaseStorageRef.read { tx in
            return (
                DependenciesBridge.shared.tsAccountManager.registrationState(tx: tx),
                regLoader.restoreLastMode(transaction: tx)
            )
        }

        if let lastMode {
            Logger.info("Found ongoing registration; continuing")
            return .registration(regLoader, lastMode)
        }
        switch tsRegistrationState {
        case .registered, .provisioned:
            // We're already registered.
            return .chatList

        case .reregistering(let reregNumber, let reregAci):
            if let reregE164 = E164(reregNumber), let reregAci {
                Logger.info("Found legacy re-registration; continuing in new registration")
                // A user who started re-registration before the new
                // registration flow shipped; kick them to new re-reg.
                return .registration(regLoader, .reRegistering(.init(e164: reregE164, aci: reregAci)))
            } else {
                // If we're missing the e164 or aci, drop into normal reg.
                Logger.info("Found legacy initial registration; continuing in new registration")
                return .registration(regLoader, .registering)
            }

        case .relinking:
            return .secondaryProvisioning

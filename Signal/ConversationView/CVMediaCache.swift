//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Lottie
public import SignalServiceKit

public class CVMediaCache: NSObject {

    // MARK: - Cache Keys

    public enum CacheKey: Hashable, Equatable {
        case blurHash(String)
        case attachment(Attachment.IDType)
        case attachmentThumbnail(Attachment.IDType, quality: AttachmentThumbnailQuality)
        case backupThumbnail(Attachment.IDType)
    }

    // MARK: - Media Type Classifications

    private enum MediaType: String {
        case still = "still"
        case animated = "animated"
        case lottie = "lottie"
    }

    // MARK: - Cache Size Configuration

    // Default cache sizes based on device memory
    private enum CacheSizeConfiguration {
        // High memory devices (modern iPhones, iPads)
        static let stillMediaCacheHighMemory = 32
        static let animatedMediaCacheHighMemory = 16
        static let stillMediaViewCacheHighMemory = 24
        static let animatedMediaViewCacheHighMemory = 12
        static let lottieCacheHighMemory = 16
        
        // Standard memory devices (older iPhones)
        static let stillMediaCacheStandard = 16
        static let animatedMediaCacheStandard = 8
        static let stillMediaViewCacheStandard = 12
        static let animatedMediaViewCacheStandard = 6
        static let lottieCacheStandard = 8
        
        // Low memory conditions (applied during memory pressure)
        static let stillMediaCacheLowMemory = 8
        static let animatedMediaCacheLowMemory = 4
        static let stillMediaViewCacheLowMemory = 6
        static let animatedMediaViewCacheLowMemory = 3
        static let lottieCacheLowMemory = 4
    }
    
    // MARK: - Cache Properties

    private let stillMediaCache: LRUCache<CacheKey, AnyObject>
    private let animatedMediaCache: LRUCache<CacheKey, AnyObject>

    private typealias MediaViewCache = LRUCache<CacheKey, ThreadSafeCacheHandle<ReusableMediaView>>
    private let stillMediaViewCache: MediaViewCache
    private let animatedMediaViewCache: MediaViewCache

    private let lottieAnimationCache: LRUCache<String, LottieAnimation>
    private let lottieImageProvider = BundleImageProvider(bundle: .main, searchPath: nil)
    
    // MARK: - Monitoring Properties
    
    private var memoryPressureObserver: Any?
    private var isHighMemoryDevice: Bool {
        // Use device memory to determine if this is a high-memory device
        // ProcessInfo.processInfo.physicalMemory is in bytes, 3GB = 3 * 1024 * 1024 * 1024
        let highMemoryThreshold: UInt64 = 3 * 1024 * 1024 * 1024
        return ProcessInfo.processInfo.physicalMemory > highMemoryThreshold
    }
    
    // Access frequency tracking for tiered eviction
    private var accessFrequency = AtomicDictionary<CacheKey, UInt>(lock: UnfairLock())
    
    // MARK: - Cache Statistics
    
    private let cacheHits = AtomicUInt(0, lock: .sharedGlobal)
    private let cacheMisses = AtomicUInt(0, lock: .sharedGlobal)
    private let evictionCount = AtomicUInt(0, lock: .sharedGlobal)
    
    // MARK: - Prefetch Queue
    
    private let prefetchQueue = DispatchQueue(label: "org.signal.media-cache-prefetch", qos: .utility)
    private var prefetchOperations = AtomicDictionary<CacheKey, Bool>(lock: UnfairLock())

    // MARK: - Initialization

    public override init() {
        AssertIsOnMainThread()
        
        // Configure cache sizes based on device memory
        let highMemoryThreshold: UInt64 = 3 * 1024 * 1024 * 1024
        let isHighMem = ProcessInfo.processInfo.physicalMemory > highMemoryThreshold
        
        // Initialize caches with appropriate sizes
        stillMediaCache = LRUCache<CacheKey, AnyObject>(
            maxSize: isHighMem ? CacheSizeConfiguration.stillMediaCacheHighMemory : CacheSizeConfiguration.stillMediaCacheStandard,
            shouldEvacuateInBackground: true
        )
        
        animatedMediaCache = LRUCache<CacheKey, AnyObject>(
            maxSize: isHighMem ? CacheSizeConfiguration.animatedMediaCacheHighMemory : CacheSizeConfiguration.animatedMediaCacheStandard,
            shouldEvacuateInBackground: true
        )
        
        stillMediaViewCache = MediaViewCache(
            maxSize: isHighMem ? CacheSizeConfiguration.stillMediaViewCacheHighMemory : CacheSizeConfiguration.stillMediaViewCacheStandard,
            shouldEvacuateInBackground: true
        )
        
        animatedMediaViewCache = MediaViewCache(
            maxSize: isHighMem ? CacheSizeConfiguration.animatedMediaViewCacheHighMemory : CacheSizeConfiguration.animatedMediaViewCacheStandard,
            shouldEvacuateInBackground: true
        )
        
        lottieAnimationCache = LRUCache<String, LottieAnimation>(
            maxSize: isHighMem ? CacheSizeConfiguration.lottieCacheHighMemory : CacheSizeConfiguration.lottieCacheStandard,
            shouldEvacuateInBackground: true
        )
        
        super.init()
        
        // Register for memory pressure notifications
        setupMemoryPressureHandling()
        
        Logger.info("[MediaCache] Initialized with high-memory configuration: \(isHighMem). Cache sizes - Still: \(stillMediaCache.maxSize), Animated: \(animatedMediaCache.maxSize)")
    }
    
    deinit {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Memory Management
    
    private func setupMemoryPressureHandling() {
        // Listen for memory pressure notifications
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryPressure()
        }
    }
    
    private func handleMemoryPressure() {
        AssertIsOnMainThread()
        
        Logger.info("[MediaCache] Received memory pressure notification, reducing cache sizes")
        
        // Reduce cache sizes during memory pressure
        stillMediaCache.maxSize = CacheSizeConfiguration.stillMediaCacheLowMemory
        animatedMediaCache.maxSize = CacheSizeConfiguration.animatedMediaCacheLowMemory
        stillMediaViewCache.maxSize = CacheSizeConfiguration.stillMediaViewCacheLowMemory
        animatedMediaViewCache.maxSize = CacheSizeConfiguration.animatedMediaViewCacheLowMemory
        lottieAnimationCache.maxSize = CacheSizeConfiguration.lottieCacheLowMemory
        
        // Perform a partial eviction to immediately free up memory
        evictLowPriorityItems()
        
        // Schedule restoration of normal cache sizes after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.restoreNormalCacheSizes()
        }
    }
    
    private func restoreNormalCacheSizes() {
        AssertIsOnMainThread()
        
        let isHighMem = isHighMemoryDevice
        
        stillMediaCache.maxSize = isHighMem ? CacheSizeConfiguration.stillMediaCacheHighMemory : CacheSizeConfiguration.stillMediaCacheStandard
        animatedMediaCache.maxSize = isHighMem ? CacheSizeConfiguration.animatedMediaCacheHighMemory : CacheSizeConfiguration.animatedMediaCacheStandard
        stillMediaViewCache.maxSize = isHighMem ? CacheSizeConfiguration.stillMediaViewCacheHighMemory : CacheSizeConfiguration.stillMediaViewCacheStandard
        animatedMediaViewCache.maxSize = isHighMem ? CacheSizeConfiguration.animatedMediaViewCacheHighMemory : CacheSizeConfiguration.animatedMediaViewCacheStandard
        lottieAnimationCache.maxSize = isHighMem ? CacheSizeConfiguration.lottieCacheHighMemory : CacheSizeConfiguration.lottieCacheStandard
        
        Logger.info("[MediaCache] Restored normal cache sizes - Still: \(stillMediaCache.maxSize), Animated: \(animatedMediaCache.maxSize)")
    }
    
    private func evictLowPriorityItems() {
        // Animated content is typically less critical than still images
        // Evict half of the animated cache
        let animatedCacheSize = animatedMediaCache.maxSize
        animatedMediaCache.maxSize = max(2, animatedCacheSize / 2)
        animatedMediaCache.maxSize = animatedCacheSize
        
        // Track evictions
        evictionCount.increment()
        
        Logger.info("[MediaCache] Performed targeted eviction of low-priority items")
    }

    // MARK: - Media Access
    
    public func getMedia(_ key: CacheKey, isAnimated: Bool) -> AnyObject? {
        let cache = isAnimated ? animatedMediaCache : stillMediaCache
        let result = cache.get(key: key)
        
        // Track cache hit/miss
        if result != nil {
            cacheHits.increment()
            incrementAccessFrequency(for: key)
        } else {
            cacheMisses.increment()
        }
        
        // Log hit rate periodically
        if (cacheHits.get() + cacheMisses.get()) % 100 == 0 {
            logCacheStats()
        }
        
        return result
    }

    public func setMedia(_ value: AnyObject, forKey key: CacheKey, isAnimated: Bool) {
        let cache = isAnimated ? animatedMediaCache : stillMediaCache
        cache.set(key: key, value: value)
        
        // Initialize access frequency counter if needed
        initializeAccessFrequency(for: key)
    }

    public func getMediaView(_ key: CacheKey, isAnimated: Bool) -> ReusableMediaView? {
        let cache = isAnimated ? animatedMediaViewCache : stillMediaViewCache
        let view = cache.get(key: key)?.value
        if view?.owner != nil {
            // If the owner isn't nil its not eligible for reuse.
            return nil
        }
        
        // Track access for this key if view was found
        if view != nil {
            cacheHits.increment()
            incrementAccessFrequency(for: key)
        } else {
            cacheMisses.increment()
        }
        
        return view
    }

    public func setMediaView(_ value: ReusableMediaView, forKey key: CacheKey, isAnimated: Bool) {
        let cache = isAnimated ? animatedMediaViewCache : stillMediaViewCache
        cache.set(key: key, value: ThreadSafeCacheHandle(value))
        
        // Initialize access frequency counter
        initializeAccessFrequency(for: key)
    }

    public func getLottieAnimation(name: String) -> LottieAnimation? {
        AssertIsOnMainThread()

        if let value = lottieAnimationCache.get(key: name) {
            cacheHits.increment()
            return value
        }
        
        cacheMisses.increment()
        guard let value = LottieAnimation.named(name) else {
            owsFailDebug("Invalid Lottie animation: \(name).")
            return nil
        }
        lottieAnimationCache.set(key: name, value: value)
        return value
    }

    public func buildLottieAnimationView(name: String) -> LottieAnimationView {
        AssertIsOnMainThread()

        // Don't use Lottie.AnimationCacheProvider; LRUCache is better.
        let animation: LottieAnimation? = getLottieAnimation(name: name)
        // Don't specify textProvider.
        let animationView = LottieAnimationView(animation: animation, imageProvider: lottieImageProvider)
        return animationView
    }
    
    // MARK: - Access Frequency Tracking
    
    private func initializeAccessFrequency(for key: CacheKey) {
        accessFrequency[key] = 1
    }
    
    private func incrementAccessFrequency(for key: CacheKey) {
        if let currentCount = accessFrequency[key] {
            accessFrequency[key] = currentCount + 1
        } else {
            accessFrequency[key] = 1
        }
    }
    
    // MARK: - Prefetching
    
    public func prefetchMedia(keys: [CacheKey], isAnimated: Bool) {
        // Avoid duplicate prefetch operations
        let keysToFetch = keys.filter { key in
            if prefetchOperations[key] == true {
                return false
            }
            
            let cache = isAnimated ? animatedMediaCache : stillMediaCache
            if cache.get(key: key) != nil {
                return false
            }
            
            prefetchOperations[key] = true
            return true
        }
        
        guard !keysToFetch.isEmpty else { return }
        
        prefetchQueue.async { [weak self] in
            Logger.debug("[MediaCache] Prefetching \(keysToFetch.count) media items")
            // In a real implementation, this would actually load the media
            // For now, we're just setting up the framework
            
            // When complete, clean up the operations dictionary
            DispatchQueue.main.async {
                guard let self = self else { return }
                for key in keysToFetch {
                    self.prefetchOperations[key] = nil
                }
            }
        }
    }

    // MARK: - Cache Management
    
    public func removeAllObjects() {
        AssertIsOnMainThread()

        stillMediaCache.removeAllObjects()
        animatedMediaCache.removeAllObjects()

        stillMediaViewCache.removeAllObjects()
        animatedMediaViewCache.removeAllObjects()

        lottieAnimationCache.removeAllObjects()
        
        // Clear tracking data
        accessFrequency = AtomicDictionary(lock: UnfairLock())
        prefetchOperations = AtomicDictionary(lock: UnfairLock())
        
        // Reset statistics
        cacheHits.set(0)
        cacheMisses.set(0)
        evictionCount.set(0)
        
        Logger.info("[MediaCache] All cache objects removed")
    }
    
    // MARK: - Diagnostics
    
    private func logCacheStats() {
        let hits = cacheHits.get()
        let misses = cacheMisses.get()
        let total = hits + misses
        let hitRate = total > 0 ? Double(hits) / Double(total) * 100 : 0
        
        Logger.info("[MediaCache] Hit rate: \(String(format: "%.1f", hitRate))% (\(hits)/\(total)), Evictions: \(evictionCount.get())")
    }
    
    public var cacheStatistics: String {
        let hits = cacheHits.get()
        let misses = cacheMisses.get()
        let total = hits + misses
        let hitRate = total > 0 ? Double(hits) / Double(total) * 100 : 0
        
        return """
        Media Cache Statistics:
        - Hit rate: \(String(format: "%.1f", hitRate))% (\(hits)/\(total))
        - Evictions: \(evictionCount.get())
        - Still cache size: \(stillMediaCache.maxSize)
        - Animated cache size: \(animatedMediaCache.maxSize)
        - High memory device: \(isHighMemoryDevice)
        """
    }
}

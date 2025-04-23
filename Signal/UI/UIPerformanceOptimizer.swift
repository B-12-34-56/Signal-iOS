import Foundation
import UIKit
import SignalServiceKit
import SignalUI

/// A utility class for optimizing UI rendering performance in Signal
public class UIPerformanceOptimizer {
    
    // MARK: - Properties
    
    private static let shared = UIPerformanceOptimizer()
    
    /// Queue for handling background image preparation
    private let imageProcessingQueue = DispatchQueue(label: "org.signal.ui-performance-image-processing", qos: .userInitiated)
    
    /// Queue for collecting performance metrics
    private let metricsQueue = DispatchQueue(label: "org.signal.ui-performance-metrics", qos: .utility)
    
    /// Property to track frame drops for performance monitoring
    private var previousFrameTimestamp: CFTimeInterval = 0
    private var droppedFramesCount: Int = 0
    private var totalFramesCount: Int = 0
    
    /// Dictionary to store cached measurement data for table/collection view cells
    private var cellMeasurementCache = NSCache<NSString, NSValue>()
    
    /// Pool of reusable views for conversation cells
    private var viewRecyclingPool = [String: [UIView]]()
    private let recyclingPoolLock = UnfairLock()
    
    // MARK: - Public API
    
    /// Get the shared instance
    public class func sharedInstance() -> UIPerformanceOptimizer {
        return shared
    }
    
    // MARK: - View Recycling
    
    /// Register a view for recycling with a specific identifier
    public func registerViewForRecycling(_ view: UIView, withIdentifier identifier: String) {
        recyclingPoolLock.withLock {
            if viewRecyclingPool[identifier] == nil {
                viewRecyclingPool[identifier] = []
            }
            viewRecyclingPool[identifier]?.append(view)
        }
        
        // Reset view state to prepare for reuse
        view.layer.removeAllAnimations()
        if let scrollView = view as? UIScrollView {
            scrollView.contentOffset = .zero
        }
    }
    
    /// Dequeue a recycled view if available, otherwise return nil
    public func dequeueRecycledView(withIdentifier identifier: String) -> UIView? {
        return recyclingPoolLock.withLock {
            return viewRecyclingPool[identifier]?.popLast()
        }
    }
    
    // MARK: - Shadow Path Optimization
    
    /// Optimize shadows for a view by setting explicit shadow paths
    public func optimizeShadowsForView(_ view: UIView, cornerRadius: CGFloat = 0) {
        guard view.layer.shadowOpacity > 0 else { return }
        
        // Create shadow path based on view bounds and corner radius
        let shadowPath = UIBezierPath(roundedRect: view.bounds, cornerRadius: cornerRadius)
        view.layer.shadowPath = shadowPath.cgPath
        
        // Ensure rasterization for complex shadow views that don't change frequently
        if view.layer.shadowRadius > 2 && view.layer.shadowOpacity > 0.2 {
            setRasterizationForStaticView(view)
        }
    }
    
    // MARK: - Cell Measurement and Caching
    
    /// Cache cell size measurement results for better performance
    public func cacheCellSize(_ size: CGSize, forReuseIdentifier reuseIdentifier: String, width: CGFloat) {
        let cacheKey = "\(reuseIdentifier)_\(width)" as NSString
        cellMeasurementCache.setObject(NSValue(cgSize: size), forKey: cacheKey)
    }
    
    /// Get cached cell size if available
    public func cachedCellSize(forReuseIdentifier reuseIdentifier: String, width: CGFloat) -> CGSize? {
        let cacheKey = "\(reuseIdentifier)_\(width)" as NSString
        guard let sizeValue = cellMeasurementCache.object(forKey: cacheKey) else {
            return nil
        }
        return sizeValue.cgSizeValue
    }
    
    /// Pre-calculate and cache cell sizes for a collection of items
    public func precalculateCellSizes<T>(items: [T], 
                                      reuseIdentifier: String,
                                      width: CGFloat,
                                      sizeCalculator: (T) -> CGSize) {
        
        imageProcessingQueue.async {
            for (index, item) in items.enumerated() {
                let size = sizeCalculator(item)
                let cacheKey = "\(reuseIdentifier)_\(width)_\(index)" as NSString
                self.cellMeasurementCache.setObject(NSValue(cgSize: size), forKey: cacheKey)
            }
        }
    }
    
    // MARK: - Image Optimization
    
    /// Decompress and prepare image in the background
    public func prepareImageAsync(_ image: UIImage, completion: @escaping (UIImage) -> Void) {
        imageProcessingQueue.async {
            let decompressedImage = self.decompressImage(image)
            DispatchQueue.main.async {
                completion(decompressedImage)
            }
        }
    }
    
    /// Decompress image off the main thread to prevent UI hitches
    private func decompressImage(_ image: UIImage) -> UIImage {
        // Force decompression by drawing the image into a context
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(at: .zero)
        guard let decompressedImage = UIGraphicsGetImageFromCurrentImageContext() else {
            return image
        }
        
        return decompressedImage
    }
    
    // MARK: - Layer Rasterization
    
    /// Optimize static complex views by enabling rasterization
    public func setRasterizationForStaticView(_ view: UIView) {
        view.layer.shouldRasterize = true
        view.layer.rasterizationScale = UIScreen.main.scale
    }
    
    /// Disable rasterization for views that will animate or change frequently
    public func disableRasterization(forView view: UIView) {
        view.layer.shouldRasterize = false
    }
    
    // MARK: - Frame Drop Detection
    
    /// Start monitoring for frame drops
    public func startFrameDropMonitoring() {
        // Reset counters
        droppedFramesCount = 0
        totalFramesCount = 0
        previousFrameTimestamp = CACurrentMediaTime()
        
        // Set up display link to track frame timing
        let displayLink = CADisplayLink(target: self, selector: #selector(frameUpdate))
        displayLink.add(to: .main, forMode: .common)
    }
    
    @objc private func frameUpdate(_ displayLink: CADisplayLink) {
        // Track frame timing
        let currentTime = CACurrentMediaTime()
        let elapsedTime = currentTime - previousFrameTimestamp
        previousFrameTimestamp = currentTime
        
        totalFramesCount += 1
        
        // If elapsed time is significantly longer than the expected frame duration,
        // we likely dropped one or more frames
        let expectedFrameDuration = 1.0 / Double(UIScreen.main.maximumFramesPerSecond)
        let frameDropThreshold = expectedFrameDuration * 1.5
        
        if elapsedTime > frameDropThreshold {
            let approximateDroppedFrames = Int((elapsedTime / expectedFrameDuration) - 1)
            droppedFramesCount += max(1, approximateDroppedFrames)
            
            // Log if we're seeing significant frame drops
            if approximateDroppedFrames > 3 {
                Logger.debug("[UIPerformanceOptimizer] Detected \(approximateDroppedFrames) dropped frames")
                captureThreadPerformance()
            }
        }
    }
    
    /// Report current frame drop statistics
    public func getFrameDropStats() -> (dropped: Int, total: Int, percentage: Double) {
        let percentage = totalFramesCount > 0 ? 
            (Double(droppedFramesCount) / Double(totalFramesCount)) * 100.0 : 0
        return (droppedFramesCount, totalFramesCount, percentage)
    }
    
    // MARK: - UI Thread Monitoring
    
    /// Begin monitoring the main thread for potential bottlenecks
    public func beginUIThreadMonitoring() {
        metricsQueue.async {
            self.monitorUIThreadBlocks()
        }
    }
    
    private func monitorUIThreadBlocks() {
        // Set up a watchdog timer to detect main thread blockages
        let watchDogTimeout: TimeInterval = 0.1 // 100ms threshold for UI responsiveness
        
        while true {
            let semaphore = DispatchSemaphore(value: 0)
            var isResponding = false
            
            // Dispatch a task to the main thread that signals when executed
            DispatchQueue.main.async {
                isResponding = true
                semaphore.signal()
            }
            
            // Wait for the main thread to execute our task
            let waitResult = semaphore.wait(timeout: .now() + watchDogTimeout)
            
            if waitResult == .timedOut && !isResponding {
                // The main thread is blocked for longer than our threshold
                self.captureThreadPerformance()
            }
            
            // Check periodically, but not too aggressively
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
    
    private func captureThreadPerformance() {
        // In a real implementation, we might collect stack traces or other diagnostics
        // Here we'll just log that we detected an issue
        Logger.info("[UIPerformanceOptimizer] Detected main thread blockage")
    }
    
    // MARK: - Conversation View Optimization
    
    /// Prepare a conversation view cell for optimal rendering
    public func optimizeConversationCell(_ cell: UIView) {
        // Apply common optimizations for conversation cells
        
        // Find image views and optimize them
        cell.subviews.forEach { subview in
            if let imageView = subview as? UIImageView {
                // Prevent color space conversions during drawing
                imageView.layer.minificationFilter = .trilinear
                
                // Optimize images with alpha
                if let image = imageView.image, image.hasAlpha() {
                    prepareImageAsync(image) { optimizedImage in
                        // Only update if the cell is still showing the same image
                        if imageView.image === image {
                            imageView.image = optimizedImage
                        }
                    }
                }
            }
            
            // Optimize shadows in the cell
            if subview.layer.shadowOpacity > 0 {
                optimizeShadowsForView(subview)
            }
        }
    }
    
    /// Transaction optimization for batched UI updates
    public func performWithoutAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }
}

// MARK: - UIImage Extension

extension UIImage {
    fileprivate func hasAlpha() -> Bool {
        guard let alphaInfo = cgImage?.alphaInfo else { return false }
        return alphaInfo != .none && 
               alphaInfo != .noneSkipFirst && 
               alphaInfo != .noneSkipLast
    }
}
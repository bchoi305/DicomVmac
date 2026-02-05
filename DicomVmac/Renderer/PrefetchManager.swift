//
//  PrefetchManager.swift
//  DicomVmac
//
//  Background prefetcher that decodes ±N slices around the current position,
//  biased toward the scroll direction.
//

import Foundation

actor PrefetchManager {

    private let cache: FrameCache
    private let bridge: DicomBridgeWrapper
    private let prefetchRadius = 8

    /// Current prefetch task — cancelled when a new prefetch is triggered.
    private var prefetchTask: Task<Void, Never>?

    init(cache: FrameCache, bridge: DicomBridgeWrapper) {
        self.cache = cache
        self.bridge = bridge
    }

    /// Trigger prefetch around the given index for a series.
    /// - Parameters:
    ///   - currentIndex: Currently displayed slice index.
    ///   - seriesRowID: The series being viewed.
    ///   - instances: All instances in the series.
    ///   - scrollDelta: Positive = scrolling forward, negative = backward, 0 = no bias.
    func prefetch(
        around currentIndex: Int,
        seriesRowID: Int64,
        instances: [Instance],
        scrollDelta: Int
    ) {
        prefetchTask?.cancel()

        let radius = prefetchRadius
        let cache = self.cache
        let bridge = self.bridge

        prefetchTask = Task.detached(priority: .utility) {
            // Build prefetch order: bias toward scroll direction
            var indices: [Int] = []
            let forwardBias = scrollDelta >= 0

            for offset in 1...radius {
                if forwardBias {
                    indices.append(currentIndex + offset)
                    indices.append(currentIndex - offset)
                } else {
                    indices.append(currentIndex - offset)
                    indices.append(currentIndex + offset)
                }
            }

            for idx in indices {
                if Task.isCancelled { break }
                guard idx >= 0 && idx < instances.count else { continue }

                let key = FrameCacheKey(seriesRowID: seriesRowID,
                                        instanceIndex: idx)
                let alreadyCached = await cache.contains(key)
                if alreadyCached { continue }

                let instance = instances[idx]
                do {
                    let frame = try bridge.decodeFrame(filePath: instance.filePath)
                    await cache.insert(key: key, frame: frame)
                } catch {
                    // Non-fatal: prefetch failure is silent
                }
            }
        }
    }

    /// Cancel any in-flight prefetch.
    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }
}

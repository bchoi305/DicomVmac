//
//  FrameCache.swift
//  DicomVmac
//
//  LRU cache for decoded DICOM frames. Budget-limited by total byte usage.
//

import Foundation

/// Key for cached frames: combination of series row ID and slice index.
struct FrameCacheKey: Hashable, Sendable {
    let seriesRowID: Int64
    let instanceIndex: Int
}

/// Actor-isolated LRU cache for decoded FrameData.
actor FrameCache {

    /// Maximum memory budget in bytes (default 512 MB).
    private let maxBytes: Int

    /// Current total memory usage in bytes.
    private var currentBytes: Int = 0

    /// Cached entries: key → frame data.
    private var cache: [FrameCacheKey: FrameData] = [:]

    /// Access order for LRU eviction (most recently used at the end).
    private var accessOrder: [FrameCacheKey] = []

    init(maxBytes: Int = 512 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    /// Get a cached frame, or decode and cache it.
    func getOrDecode(
        key: FrameCacheKey,
        decode: @Sendable () throws -> FrameData
    ) throws -> FrameData {
        if let frame = cache[key] {
            touchKey(key)
            return frame
        }

        let frame = try decode()
        insert(key: key, frame: frame)
        return frame
    }

    /// Check if a key is already cached.
    func contains(_ key: FrameCacheKey) -> Bool {
        cache[key] != nil
    }

    /// Insert a frame into the cache, evicting as needed.
    func insert(key: FrameCacheKey, frame: FrameData) {
        let frameBytes = frame.width * frame.height * MemoryLayout<UInt16>.size
        evictIfNeeded(toFit: frameBytes)

        cache[key] = frame
        accessOrder.append(key)
        currentBytes += frameBytes
    }

    /// Clear all cached frames.
    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
        currentBytes = 0
    }

    /// Clear frames for a specific series.
    func clearSeries(_ seriesRowID: Int64) {
        let keysToRemove = cache.keys.filter { $0.seriesRowID == seriesRowID }
        for key in keysToRemove {
            removeKey(key)
        }
    }

    // MARK: - Private

    private func touchKey(_ key: FrameCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func removeKey(_ key: FrameCacheKey) {
        if let frame = cache.removeValue(forKey: key) {
            let frameBytes = frame.width * frame.height * MemoryLayout<UInt16>.size
            currentBytes -= frameBytes
        }
        accessOrder.removeAll { $0 == key }
    }

    private func evictIfNeeded(toFit newBytes: Int) {
        while currentBytes + newBytes > maxBytes && !accessOrder.isEmpty {
            let oldest = accessOrder.removeFirst()
            if let frame = cache.removeValue(forKey: oldest) {
                let frameBytes = frame.width * frame.height * MemoryLayout<UInt16>.size
                currentBytes -= frameBytes
            }
        }
    }
}

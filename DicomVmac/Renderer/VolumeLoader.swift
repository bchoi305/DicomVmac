//
//  VolumeLoader.swift
//  DicomVmac
//
//  Loads a DICOM series into a contiguous 3D volume buffer for MPR rendering.
//  Sorts slices by Z position and validates uniform dimensions.
//

import Foundation

/// Loads DICOM series data into a 3D volume suitable for MPR rendering.
final class VolumeLoader: Sendable {

    private let bridge: DicomBridgeWrapper

    init(bridge: DicomBridgeWrapper = DicomBridgeWrapper()) {
        self.bridge = bridge
    }

    /// Load a volume from a series.
    /// - Parameters:
    ///   - series: The series metadata.
    ///   - instances: All instances in the series, ordered by instanceNumber.
    ///   - progress: Optional callback for progress updates (slicesLoaded, totalSlices).
    /// - Returns: Volume metadata and contiguous pixel buffer (slices stacked in Z order).
    func loadVolume(
        series: Series,
        instances: [Instance],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (VolumeData, [UInt16]) {

        guard !instances.isEmpty else {
            throw VolumeLoadError.noInstances
        }

        guard instances.count >= 3 else {
            throw VolumeLoadError.insufficientSlices(count: instances.count)
        }

        // Decode all frames to get pixel data and Z positions
        var frameInfos: [(instance: Instance, frame: FrameData)] = []
        frameInfos.reserveCapacity(instances.count)

        for (index, instance) in instances.enumerated() {
            do {
                let frame = try bridge.decodeFrame(filePath: instance.filePath)
                frameInfos.append((instance, frame))
                progress?(index + 1, instances.count)
            } catch {
                throw VolumeLoadError.decodeFailed(
                    sopInstanceUID: instance.sopInstanceUID,
                    underlying: error
                )
            }
        }

        // Sort by imagePositionZ if available, otherwise by instanceNumber
        let sorted = sortSlices(frameInfos)

        // Validate dimensions are consistent
        guard let firstFrame = sorted.first?.frame else {
            throw VolumeLoadError.noInstances
        }

        let width = firstFrame.width
        let height = firstFrame.height
        let bitsStored = firstFrame.bitsStored

        for (_, frame) in sorted {
            if frame.width != width || frame.height != height {
                throw VolumeLoadError.inconsistentDimensions
            }
        }

        // Calculate slice spacing
        let sliceSpacing = calculateSliceSpacing(sorted.map { $0.frame })

        // Build contiguous pixel buffer
        let depth = sorted.count
        var volumePixels = [UInt16]()
        volumePixels.reserveCapacity(width * height * depth)

        for (_, frame) in sorted {
            volumePixels.append(contentsOf: frame.pixels)
        }

        // Use first frame for default W/L and spacing
        let volumeData = VolumeData(
            seriesRowID: series.id ?? 0,
            width: width,
            height: height,
            depth: depth,
            pixelSpacingX: firstFrame.pixelSpacingX ?? 1.0,
            pixelSpacingY: firstFrame.pixelSpacingY ?? 1.0,
            sliceSpacing: sliceSpacing,
            rescaleSlope: firstFrame.rescaleSlope,
            rescaleIntercept: firstFrame.rescaleIntercept,
            windowCenter: firstFrame.windowCenter,
            windowWidth: firstFrame.windowWidth,
            bitsStored: bitsStored
        )

        return (volumeData, volumePixels)
    }

    // MARK: - Private

    /// Sort slices by Z position (imagePositionZ) if available, otherwise by instanceNumber.
    private func sortSlices(
        _ frameInfos: [(instance: Instance, frame: FrameData)]
    ) -> [(instance: Instance, frame: FrameData)] {

        // Check if we have Z positions for all slices
        let allHaveZPosition = frameInfos.allSatisfy { $0.frame.imagePositionZ != nil }

        if allHaveZPosition {
            // Sort by imagePositionZ (ascending for standard head-to-foot orientation)
            return frameInfos.sorted { a, b in
                let zA = a.frame.imagePositionZ ?? 0
                let zB = b.frame.imagePositionZ ?? 0
                return zA < zB
            }
        } else {
            // Fall back to instanceNumber ordering
            return frameInfos.sorted { a, b in
                let numA = a.instance.instanceNumber ?? 0
                let numB = b.instance.instanceNumber ?? 0
                return numA < numB
            }
        }
    }

    /// Calculate average slice spacing from Z positions.
    private func calculateSliceSpacing(_ frames: [FrameData]) -> Double {
        // Try to calculate from Z positions
        var spacings: [Double] = []

        for i in 1..<frames.count {
            if let z0 = frames[i - 1].imagePositionZ,
               let z1 = frames[i].imagePositionZ {
                let spacing = abs(z1 - z0)
                if spacing > 0.001 { // Avoid near-zero values
                    spacings.append(spacing)
                }
            }
        }

        if !spacings.isEmpty {
            return spacings.reduce(0, +) / Double(spacings.count)
        }

        // Fall back to sliceThickness from first frame
        if let thickness = frames.first?.sliceThickness, thickness > 0 {
            return thickness
        }

        // Default to 1mm if nothing else available
        return 1.0
    }
}

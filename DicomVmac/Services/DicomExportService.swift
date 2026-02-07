//
//  DicomExportService.swift
//  DicomVmac
//
//  Service for exporting DICOM images to standard formats.
//

import Foundation
import AppKit

/// Service for DICOM export and format conversion
final class DicomExportService: Sendable {

    private let bridge: DicomBridgeWrapper
    private let database: DatabaseManager

    init(bridge: DicomBridgeWrapper, database: DatabaseManager) {
        self.bridge = bridge
        self.database = database
    }

    // MARK: - Export Operations

    /// Export images based on options
    func export(
        instances: [Instance],
        options: DicomExportOptions,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> ExportResult {
        guard let destinationURL = options.destinationURL else {
            throw ExportError.noDestination
        }

        // Create destination directory
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )

        var successCount = 0
        var failureCount = 0
        var exportedFiles: [URL] = []
        var errors: [String] = []

        // Export each instance
        for (index, instance) in instances.enumerated() {
            do {
                let fileURL = try await exportInstance(
                    instance,
                    options: options,
                    index: index,
                    totalCount: instances.count
                )
                exportedFiles.append(fileURL)
                successCount += 1
            } catch {
                failureCount += 1
                errors.append("\(instance.sopInstanceUID): \(error.localizedDescription)")
            }

            // Report progress
            onProgress(index + 1, instances.count)
        }

        return ExportResult(
            successCount: successCount,
            failureCount: failureCount,
            exportedFiles: exportedFiles,
            errors: errors
        )
    }

    // MARK: - Single Instance Export

    private func exportInstance(
        _ instance: Instance,
        options: DicomExportOptions,
        index: Int,
        totalCount: Int
    ) async throws -> URL {
        // Load DICOM frame
        let frame = try await loadFrame(from: instance.filePath)

        // Apply window/level
        let processedPixels = applyWindowLevel(
            pixels: frame.pixels,
            width: Int(frame.width),
            height: Int(frame.height),
            bitsStored: Int(frame.bitsStored),
            windowCenter: frame.windowCenter,
            windowWidth: frame.windowWidth,
            options: options
        )

        // Convert to output format
        let imageData = try createImageData(
            pixels: processedPixels,
            width: Int(frame.width),
            height: Int(frame.height),
            options: options
        )

        // Generate filename
        let filename = options.generateFilename(
            patientID: instance.sopInstanceUID,  // TODO: Get from study/patient
            studyDate: "",  // TODO: Get from study
            seriesNumber: 0,  // TODO: Get from series
            instanceNumber: instance.instanceNumber ?? index,
            sopInstanceUID: instance.sopInstanceUID,
            index: index
        )

        // Determine output URL
        var outputURL = options.destinationURL!.appendingPathComponent(filename)

        // Create subfolders if requested
        if options.includeSubfolders {
            let seriesFolder = options.destinationURL!
                .appendingPathComponent("Series_\(instance.seriesRowID)")
            try FileManager.default.createDirectory(
                at: seriesFolder,
                withIntermediateDirectories: true
            )
            outputURL = seriesFolder.appendingPathComponent(filename)
        }

        // Write to file
        try imageData.write(to: outputURL)

        // Clean up frame buffer
        db_free_buffer(frame.pixels)

        return outputURL
    }

    // MARK: - Image Processing

    private func loadFrame(from filePath: String) async throws -> DB_Frame16 {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                var frame = DB_Frame16()
                let status = db_decode_frame16(filePath, 0, &frame)

                guard status == DB_STATUS_OK else {
                    continuation.resume(throwing: ExportError.decodeFailed(path: filePath))
                    return
                }

                guard frame.pixels != nil else {
                    continuation.resume(throwing: ExportError.noPixelData)
                    return
                }

                continuation.resume(returning: frame)
            }
        }
    }

    private func applyWindowLevel(
        pixels: UnsafeMutablePointer<UInt16>,
        width: Int,
        height: Int,
        bitsStored: Int,
        windowCenter: Double,
        windowWidth: Double,
        options: DicomExportOptions
    ) -> [UInt8] {
        let pixelCount = width * height
        var output = [UInt8](repeating: 0, count: pixelCount)

        // Determine window/level to use
        var wc = windowCenter
        var ww = windowWidth

        switch options.windowPreset {
        case .custom:
            wc = options.customWindowCenter
            ww = options.customWindowWidth
        case .original:
            // Use values from DICOM (already set)
            break
        case .fullRange:
            // Calculate min/max from pixel data
            let buffer = UnsafeBufferPointer(start: pixels, count: pixelCount)
            let minVal = Double(buffer.min() ?? 0)
            let maxVal = Double(buffer.max() ?? 0)
            wc = (minVal + maxVal) / 2.0
            ww = maxVal - minVal
        default:
            // Use preset values
            if let preset = options.windowPreset.windowValues {
                wc = preset.center
                ww = preset.width
            }
        }

        // Apply window/level transformation
        let minValue = wc - ww / 2.0
        let maxValue = wc + ww / 2.0
        let range = maxValue - minValue

        guard range > 0 else {
            return output
        }

        for i in 0..<pixelCount {
            let pixelValue = Double(pixels[i])
            var normalized: Double

            if pixelValue <= minValue {
                normalized = 0
            } else if pixelValue >= maxValue {
                normalized = 1
            } else {
                normalized = (pixelValue - minValue) / range
            }

            output[i] = UInt8(normalized * 255.0)
        }

        return output
    }

    private func createImageData(
        pixels: [UInt8],
        width: Int,
        height: Int,
        options: DicomExportOptions
    ) throws -> Data {
        // Create CGImage from pixel data
        guard let dataProvider = CGDataProvider(
            data: Data(pixels) as CFData
        ) else {
            throw ExportError.imageCreationFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw ExportError.imageCreationFailed
        }

        // Create NSBitmapImageRep
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)

        // Convert to desired format
        switch options.format {
        case .jpeg:
            guard let data = bitmapRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: NSNumber(value: options.quality)]
            ) else {
                throw ExportError.conversionFailed(format: "JPEG")
            }
            return data

        case .png:
            guard let data = bitmapRep.representation(
                using: .png,
                properties: [:]
            ) else {
                throw ExportError.conversionFailed(format: "PNG")
            }
            return data

        case .tiff:
            guard let data = bitmapRep.representation(
                using: .tiff,
                properties: [.compressionMethod: NSNumber(value: NSBitmapImageRep.TIFFCompression.none.rawValue)]
            ) else {
                throw ExportError.conversionFailed(format: "TIFF")
            }
            return data
        }
    }

    // MARK: - Batch Export Helpers

    /// Get instances for export based on scope
    func getInstances(
        for scope: ExportScope,
        currentInstance: Instance?,
        currentSeriesRowID: Int64?,
        currentStudyRowID: Int64?
    ) throws -> [Instance] {
        switch scope {
        case .currentImage:
            guard let instance = currentInstance else {
                throw ExportError.noSelection
            }
            return [instance]

        case .currentSeries:
            guard let seriesRowID = currentSeriesRowID else {
                throw ExportError.noSelection
            }
            return try database.fetchInstances(forSeries: seriesRowID)

        case .currentStudy:
            guard let studyRowID = currentStudyRowID else {
                throw ExportError.noSelection
            }
            // Get all series in study, then all instances
            let seriesList = try database.fetchSeries(forStudy: studyRowID)
            return try seriesList.flatMap { series in
                try database.fetchInstances(forSeries: series.id!)
            }

        case .selection:
            // Would need to be passed in from UI
            throw ExportError.notImplemented
        }
    }
}

// MARK: - Errors

enum ExportError: Error, LocalizedError {
    case noDestination
    case noSelection
    case decodeFailed(path: String)
    case noPixelData
    case imageCreationFailed
    case conversionFailed(format: String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .noDestination:
            return "No destination folder specified"
        case .noSelection:
            return "No image or series selected for export"
        case .decodeFailed(let path):
            return "Failed to decode DICOM file: \(path)"
        case .noPixelData:
            return "No pixel data found in DICOM file"
        case .imageCreationFailed:
            return "Failed to create image from pixel data"
        case .conversionFailed(let format):
            return "Failed to convert image to \(format) format"
        case .notImplemented:
            return "This feature is not yet implemented"
        }
    }
}

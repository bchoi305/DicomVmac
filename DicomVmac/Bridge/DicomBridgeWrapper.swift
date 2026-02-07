//
//  DicomBridgeWrapper.swift
//  DicomVmac
//
//  Swift wrapper around the C ABI DicomBridge functions.
//  Provides a safe, Swift-native API.
//

import Foundation

/// Swift wrapper for the DicomCore C bridge.
/// Manages the opaque DB_Context lifecycle and provides async-safe methods.
final class DicomBridgeWrapper: @unchecked Sendable {

    private let context: OpaquePointer

    init() {
        context = db_create()
    }

    deinit {
        db_destroy(context)
    }

    /// Returns the DicomCore library version string.
    var version: String {
        String(cString: db_version())
    }

    /// Decode a single frame from a DICOM file.
    /// - Parameters:
    ///   - filePath: Path to the DICOM file.
    ///   - frameIndex: Zero-based frame index.
    /// - Returns: A FrameData struct with pixel data and metadata.
    func decodeFrame(filePath: String, frameIndex: Int = 0) throws -> FrameData {
        var frame = DB_Frame16()
        let status = db_decode_frame16(filePath, Int32(frameIndex), &frame)

        guard status == DB_STATUS_OK else {
            throw DicomBridgeError.decodeFailed(status: status)
        }

        defer { db_free_buffer(frame.pixels) }

        guard let pixels = frame.pixels else {
            throw DicomBridgeError.nullPixelData
        }

        let count = Int(frame.width) * Int(frame.height)
        let pixelArray = Array(UnsafeBufferPointer(start: pixels, count: count))

        return FrameData(
            pixels: pixelArray,
            width: Int(frame.width),
            height: Int(frame.height),
            bitsStored: Int(frame.bitsStored),
            rescaleSlope: Double(frame.rescaleSlope),
            rescaleIntercept: Double(frame.rescaleIntercept),
            windowCenter: frame.windowCenter,
            windowWidth: frame.windowWidth,
            pixelSpacingX: frame.hasPixelSpacing != 0 ? frame.pixelSpacingX : nil,
            pixelSpacingY: frame.hasPixelSpacing != 0 ? frame.pixelSpacingY : nil,
            imagePositionZ: frame.hasImagePosition != 0 ? frame.imagePositionZ : nil,
            sliceThickness: frame.sliceThickness > 0 ? frame.sliceThickness : nil
        )
    }

    /// Extract DICOM tags from a file without pixel decoding.
    func extractTags(filePath: String) throws -> DicomTagData {
        var tags = DB_DicomTags()
        let status = db_extract_tags(filePath, &tags)

        guard status == DB_STATUS_OK else {
            throw DicomBridgeError.decodeFailed(status: status)
        }

        return DicomTagData.from(tags: &tags, filePath: filePath)
    }

    /// Scan a folder recursively for DICOM files.
    /// Calls onFile for each valid DICOM file and onProgress periodically.
    func scanFolder(
        path: String,
        onFile: @escaping @Sendable (DicomTagData) -> Void,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) throws {
        let ctx = ScanContext(onFile: onFile, onProgress: onProgress)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        defer { Unmanaged<ScanContext>.fromOpaque(ctxPtr).release() }

        let fileCallback: DB_ScanCallback = { userData, tagsPtr, filePathPtr in
            guard let userData, let tagsPtr, let filePathPtr else { return }
            let ctx = Unmanaged<ScanContext>.fromOpaque(userData)
                .takeUnretainedValue()
            let filePath = String(cString: filePathPtr)
            let tagData = DicomTagData.from(tagsPtr: tagsPtr, filePath: filePath)
            ctx.onFile(tagData)
        }

        let progressCallback: DB_ScanProgressCallback = { userData, scanned, found in
            guard let userData else { return }
            let ctx = Unmanaged<ScanContext>.fromOpaque(userData)
                .takeUnretainedValue()
            ctx.onProgress(Int(scanned), Int(found))
        }

        let status = db_scan_folder(path, fileCallback, progressCallback, ctxPtr)
        guard status == DB_STATUS_OK else {
            throw DicomBridgeError.decodeFailed(status: status)
        }
    }

    // MARK: - DICOMDIR Support

    /// Check if a path points to a DICOMDIR file or folder containing one.
    func isDicomdir(path: String) -> Bool {
        return db_is_dicomdir(path) != 0
    }

    /// Scan a DICOMDIR file and extract metadata from referenced files.
    /// - Parameters:
    ///   - path: Path to DICOMDIR file or folder containing one.
    ///   - onFile: Called for each valid DICOM file found.
    ///   - onProgress: Called periodically with (recordsProcessed, filesFound).
    func scanDicomdir(
        path: String,
        onFile: @escaping @Sendable (DicomTagData) -> Void,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) throws {
        let ctx = ScanContext(onFile: onFile, onProgress: onProgress)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        defer { Unmanaged<ScanContext>.fromOpaque(ctxPtr).release() }

        let fileCallback: DB_DicomdirFileCallback = { userData, tagsPtr, filePathPtr in
            guard let userData, let tagsPtr, let filePathPtr else { return }
            let ctx = Unmanaged<ScanContext>.fromOpaque(userData)
                .takeUnretainedValue()
            let filePath = String(cString: filePathPtr)
            let tagData = DicomTagData.from(tagsPtr: tagsPtr, filePath: filePath)
            ctx.onFile(tagData)
        }

        let progressCallback: DB_DicomdirProgressCallback = { userData, processed, found in
            guard let userData else { return }
            let ctx = Unmanaged<ScanContext>.fromOpaque(userData)
                .takeUnretainedValue()
            ctx.onProgress(Int(processed), Int(found))
        }

        let status = db_scan_dicomdir(path, fileCallback, progressCallback, ctxPtr)
        guard status == DB_STATUS_OK else {
            throw DicomBridgeError.decodeFailed(status: status)
        }
    }
}

// MARK: - Scan Context (bridging Swift closures through C callbacks)

private final class ScanContext {
    let onFile: (DicomTagData) -> Void
    let onProgress: (Int, Int) -> Void

    init(onFile: @escaping (DicomTagData) -> Void,
         onProgress: @escaping (Int, Int) -> Void) {
        self.onFile = onFile
        self.onProgress = onProgress
    }
}

// MARK: - Data Types

/// Safely convert a C char tuple (fixed-size array) to a Swift String.
private func stringFromCTuple<T>(_ tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

struct DicomTagData: Sendable {
    let filePath: String
    let patientID: String
    let patientName: String
    let birthDate: String
    let studyInstanceUID: String
    let studyDate: String
    let studyDescription: String
    let accessionNumber: String
    let studyModality: String
    let seriesInstanceUID: String
    let seriesNumber: Int
    let seriesDescription: String
    let seriesModality: String
    let sopInstanceUID: String
    let instanceNumber: Int
    let rows: Int
    let columns: Int
    let bitsAllocated: Int

    static func from(tags: inout DB_DicomTags, filePath: String) -> DicomTagData {
        DicomTagData(
            filePath: filePath,
            patientID: stringFromCTuple(&tags.patientID),
            patientName: stringFromCTuple(&tags.patientName),
            birthDate: stringFromCTuple(&tags.birthDate),
            studyInstanceUID: stringFromCTuple(&tags.studyInstanceUID),
            studyDate: stringFromCTuple(&tags.studyDate),
            studyDescription: stringFromCTuple(&tags.studyDescription),
            accessionNumber: stringFromCTuple(&tags.accessionNumber),
            studyModality: stringFromCTuple(&tags.studyModality),
            seriesInstanceUID: stringFromCTuple(&tags.seriesInstanceUID),
            seriesNumber: Int(tags.seriesNumber),
            seriesDescription: stringFromCTuple(&tags.seriesDescription),
            seriesModality: stringFromCTuple(&tags.seriesModality),
            sopInstanceUID: stringFromCTuple(&tags.sopInstanceUID),
            instanceNumber: Int(tags.instanceNumber),
            rows: Int(tags.rows),
            columns: Int(tags.columns),
            bitsAllocated: Int(tags.bitsAllocated)
        )
    }

    /// Build from a const pointer to tags (used in C callbacks).
    static func from(tagsPtr: UnsafePointer<DB_DicomTags>,
                     filePath: String) -> DicomTagData {
        var tags = tagsPtr.pointee
        return from(tags: &tags, filePath: filePath)
    }
}

struct FrameData: Sendable {
    let pixels: [UInt16]
    let width: Int
    let height: Int
    let bitsStored: Int
    let rescaleSlope: Double
    let rescaleIntercept: Double
    let windowCenter: Double
    let windowWidth: Double
    let pixelSpacingX: Double?  // mm per pixel (column direction), nil if unknown
    let pixelSpacingY: Double?  // mm per pixel (row direction), nil if unknown
    let imagePositionZ: Double? // Z component of ImagePositionPatient, nil if unknown
    let sliceThickness: Double? // SliceThickness tag value, nil if unknown
}

enum DicomBridgeError: Error, LocalizedError {
    case decodeFailed(status: DB_Status)
    case nullPixelData

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let status):
            return "DICOM decode failed with status: \(status.rawValue)"
        case .nullPixelData:
            return "Decoded frame returned null pixel data"
        }
    }
}

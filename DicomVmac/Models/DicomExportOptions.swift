//
//  DicomExportOptions.swift
//  DicomVmac
//
//  Models for DICOM export and format conversion options.
//

import Foundation

/// Image export format options
enum ExportFormat: String, CaseIterable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    var supportsCompression: Bool {
        switch self {
        case .jpeg: return true
        case .png: return true
        case .tiff: return false
        }
    }

    var supports16Bit: Bool {
        switch self {
        case .jpeg: return false
        case .png: return true
        case .tiff: return true
        }
    }
}

/// Window/level preset for export
enum ExportWindowPreset: String, CaseIterable, Sendable {
    case custom = "Custom"
    case original = "Original (from DICOM)"
    case fullRange = "Full Range"
    case lungWindow = "Lung (CT: -600/1600)"
    case boneWindow = "Bone (CT: 400/1800)"
    case brainWindow = "Brain (CT: 40/80)"
    case abdomenWindow = "Abdomen (CT: 60/400)"
    case liverWindow = "Liver (CT: 30/150)"

    var windowValues: (center: Double, width: Double)? {
        switch self {
        case .custom, .original, .fullRange:
            return nil
        case .lungWindow:
            return (center: -600, width: 1600)
        case .boneWindow:
            return (center: 400, width: 1800)
        case .brainWindow:
            return (center: 40, width: 80)
        case .abdomenWindow:
            return (center: 60, width: 400)
        case .liverWindow:
            return (center: 30, width: 150)
        }
    }
}

/// File naming convention for exported files
enum ExportNamingConvention: String, CaseIterable, Sendable {
    case patientID = "PatientID_SeriesNumber_InstanceNumber"
    case studyDate = "StudyDate_SeriesNumber_InstanceNumber"
    case sequential = "Image_001, Image_002, ..."
    case sopInstanceUID = "SOPInstanceUID"
    case custom = "Custom Pattern"

    var description: String {
        switch self {
        case .patientID:
            return "Uses Patient ID + Series + Instance"
        case .studyDate:
            return "Uses Study Date + Series + Instance"
        case .sequential:
            return "Simple sequential numbering"
        case .sopInstanceUID:
            return "Uses DICOM SOP Instance UID"
        case .custom:
            return "User-defined pattern"
        }
    }
}

/// Export scope (what to export)
enum ExportScope: String, CaseIterable, Sendable {
    case currentImage = "Current Image"
    case currentSeries = "Current Series"
    case currentStudy = "Current Study"
    case selection = "Selected Images"

    var description: String {
        switch self {
        case .currentImage:
            return "Export the currently displayed image"
        case .currentSeries:
            return "Export all images in the current series"
        case .currentStudy:
            return "Export all series in the current study"
        case .selection:
            return "Export selected images only"
        }
    }
}

/// Comprehensive export options
struct DicomExportOptions: Sendable {

    // Format options
    var format: ExportFormat = .jpeg
    var quality: Double = 0.9  // 0.0 to 1.0 for JPEG/PNG
    var use16Bit: Bool = false  // Use 16-bit when available (PNG/TIFF)

    // Window/Level options
    var windowPreset: ExportWindowPreset = .original
    var customWindowCenter: Double = 0
    var customWindowWidth: Double = 0

    // Scope
    var scope: ExportScope = .currentSeries

    // Naming
    var namingConvention: ExportNamingConvention = .patientID
    var customPattern: String = ""  // Used when namingConvention is .custom
    var includeSubfolders: Bool = true  // Create subfolders per series

    // Metadata
    var embedMetadata: Bool = true  // Embed patient info in EXIF/metadata
    var anonymize: Bool = false  // Strip patient identifiable info

    // Destination
    var destinationURL: URL?

    /// Generate filename for a given instance
    func generateFilename(
        patientID: String,
        studyDate: String,
        seriesNumber: Int,
        instanceNumber: Int,
        sopInstanceUID: String,
        index: Int
    ) -> String {
        let basename: String

        switch namingConvention {
        case .patientID:
            basename = "\(sanitize(patientID))_S\(seriesNumber)_I\(instanceNumber)"
        case .studyDate:
            basename = "\(studyDate)_S\(seriesNumber)_I\(instanceNumber)"
        case .sequential:
            basename = String(format: "Image_%03d", index + 1)
        case .sopInstanceUID:
            basename = sanitize(sopInstanceUID)
        case .custom:
            // Simple pattern substitution
            basename = customPattern
                .replacingOccurrences(of: "{PatientID}", with: sanitize(patientID))
                .replacingOccurrences(of: "{StudyDate}", with: studyDate)
                .replacingOccurrences(of: "{SeriesNumber}", with: "\(seriesNumber)")
                .replacingOccurrences(of: "{InstanceNumber}", with: "\(instanceNumber)")
                .replacingOccurrences(of: "{Index}", with: "\(index + 1)")
        }

        return "\(basename).\(format.fileExtension)"
    }

    /// Sanitize string for use in filename
    private func sanitize(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return string.components(separatedBy: allowed.inverted).joined(separator: "_")
    }
}

/// Result of an export operation
struct ExportResult: Sendable {
    let successCount: Int
    let failureCount: Int
    let exportedFiles: [URL]
    let errors: [String]

    var isSuccess: Bool {
        failureCount == 0 && successCount > 0
    }

    var summary: String {
        if isSuccess {
            return "\(successCount) image\(successCount == 1 ? "" : "s") exported successfully"
        } else {
            return "\(successCount) succeeded, \(failureCount) failed"
        }
    }
}

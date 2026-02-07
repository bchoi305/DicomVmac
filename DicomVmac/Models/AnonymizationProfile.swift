//
//  AnonymizationProfile.swift
//  DicomVmac
//
//  Models for DICOM anonymization profiles and tag handling rules.
//

import Foundation

/// Action to take on a DICOM tag during anonymization
enum TagAction: String, Codable, Sendable {
    case remove         // Remove the tag entirely
    case replace        // Replace with a specific value
    case hash           // Replace with a hash of the original value
    case keep           // Keep the original value
    case empty          // Replace with an empty string
    case generateUID    // Generate a new UID
}

/// Rule for handling a specific DICOM tag
struct TagRule: Codable, Sendable, Identifiable {
    let id: UUID
    let tagName: String           // e.g., "PatientName"
    let tagCode: String           // e.g., "(0010,0010)"
    let action: TagAction
    let replacementValue: String? // Used when action is .replace

    init(
        id: UUID = UUID(),
        tagName: String,
        tagCode: String,
        action: TagAction,
        replacementValue: String? = nil
    ) {
        self.id = id
        self.tagName = tagName
        self.tagCode = tagCode
        self.action = action
        self.replacementValue = replacementValue
    }
}

/// Date shifting strategy
enum DateShiftStrategy: String, Codable, CaseIterable, Sendable {
    case none           = "No Date Shifting"
    case random         = "Random Shift (per patient)"
    case fixed          = "Fixed Shift Amount"
    case remove         = "Remove All Dates"

    var description: String {
        switch self {
        case .none:
            return "Keep original dates"
        case .random:
            return "Shift dates by random amount (consistent per patient)"
        case .fixed:
            return "Shift all dates by specified number of days"
        case .remove:
            return "Remove all date and time tags"
        }
    }
}

/// Patient ID mapping strategy
enum PatientIDMappingStrategy: String, Codable, CaseIterable, Sendable {
    case sequential     = "Sequential (ANON0001, ANON0002, ...)"
    case hash           = "Hash of Original ID"
    case custom         = "Custom Prefix + Number"
    case remove         = "Remove Patient ID"

    var description: String {
        switch self {
        case .sequential:
            return "Generate sequential anonymous IDs"
        case .hash:
            return "Use hash of original ID for consistency"
        case .custom:
            return "Use custom prefix with sequential numbers"
        case .remove:
            return "Remove patient ID entirely"
        }
    }
}

/// Comprehensive anonymization profile
struct AnonymizationProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isBuiltIn: Bool
    var tagRules: [TagRule]

    // Date handling
    var dateShiftStrategy: DateShiftStrategy
    var dateShiftDays: Int?  // Used with .fixed strategy

    // Patient ID handling
    var patientIDStrategy: PatientIDMappingStrategy
    var patientIDPrefix: String  // Used with .custom strategy
    var maintainPatientMapping: Bool  // Keep a mapping database

    // UIDs
    var replaceStudyInstanceUID: Bool
    var replaceSeriesInstanceUID: Bool
    var replaceSOPInstanceUID: Bool

    // Additional options
    var removePrivateTags: Bool
    var removeCurves: Bool
    var removeOverlays: Bool

    init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool = false,
        tagRules: [TagRule] = [],
        dateShiftStrategy: DateShiftStrategy = .random,
        dateShiftDays: Int? = nil,
        patientIDStrategy: PatientIDMappingStrategy = .sequential,
        patientIDPrefix: String = "ANON",
        maintainPatientMapping: Bool = true,
        replaceStudyInstanceUID: Bool = true,
        replaceSeriesInstanceUID: Bool = true,
        replaceSOPInstanceUID: Bool = true,
        removePrivateTags: Bool = true,
        removeCurves: Bool = true,
        removeOverlays: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.tagRules = tagRules
        self.dateShiftStrategy = dateShiftStrategy
        self.dateShiftDays = dateShiftDays
        self.patientIDStrategy = patientIDStrategy
        self.patientIDPrefix = patientIDPrefix
        self.maintainPatientMapping = maintainPatientMapping
        self.replaceStudyInstanceUID = replaceStudyInstanceUID
        self.replaceSeriesInstanceUID = replaceSeriesInstanceUID
        self.replaceSOPInstanceUID = replaceSOPInstanceUID
        self.removePrivateTags = removePrivateTags
        self.removeCurves = removeCurves
        self.removeOverlays = removeOverlays
    }

    // MARK: - Built-in Profiles

    /// Basic anonymization - removes obvious identifying information
    static var basicProfile: AnonymizationProfile {
        AnonymizationProfile(
            name: "Basic Anonymization",
            isBuiltIn: true,
            tagRules: [
                // Patient Information
                TagRule(tagName: "PatientName", tagCode: "(0010,0010)", action: .replace, replacementValue: "ANONYMOUS"),
                TagRule(tagName: "PatientID", tagCode: "(0010,0020)", action: .hash),
                TagRule(tagName: "PatientBirthDate", tagCode: "(0010,0030)", action: .empty),
                TagRule(tagName: "PatientSex", tagCode: "(0010,0040)", action: .keep),
                TagRule(tagName: "PatientAge", tagCode: "(0010,1010)", action: .keep),

                // Other Identifiers
                TagRule(tagName: "InstitutionName", tagCode: "(0008,0080)", action: .empty),
                TagRule(tagName: "ReferringPhysicianName", tagCode: "(0008,0090)", action: .empty),
                TagRule(tagName: "PerformingPhysicianName", tagCode: "(0008,1050)", action: .empty),
            ],
            dateShiftStrategy: .random,
            patientIDStrategy: .hash,
            maintainPatientMapping: true,
            removePrivateTags: false
        )
    }

    /// Full anonymization - removes all identifying information
    static var fullProfile: AnonymizationProfile {
        AnonymizationProfile(
            name: "Full Anonymization",
            isBuiltIn: true,
            tagRules: [
                // Patient Information
                TagRule(tagName: "PatientName", tagCode: "(0010,0010)", action: .replace, replacementValue: "ANONYMOUS"),
                TagRule(tagName: "PatientID", tagCode: "(0010,0020)", action: .hash),
                TagRule(tagName: "PatientBirthDate", tagCode: "(0010,0030)", action: .empty),
                TagRule(tagName: "PatientSex", tagCode: "(0010,0040)", action: .empty),
                TagRule(tagName: "PatientAge", tagCode: "(0010,1010)", action: .empty),
                TagRule(tagName: "PatientWeight", tagCode: "(0010,1030)", action: .empty),
                TagRule(tagName: "PatientAddress", tagCode: "(0010,1040)", action: .remove),
                TagRule(tagName: "PatientTelephoneNumbers", tagCode: "(0010,2154)", action: .remove),

                // Institution/Personnel
                TagRule(tagName: "InstitutionName", tagCode: "(0008,0080)", action: .empty),
                TagRule(tagName: "InstitutionAddress", tagCode: "(0008,0081)", action: .remove),
                TagRule(tagName: "ReferringPhysicianName", tagCode: "(0008,0090)", action: .empty),
                TagRule(tagName: "PerformingPhysicianName", tagCode: "(0008,1050)", action: .empty),
                TagRule(tagName: "OperatorsName", tagCode: "(0008,1070)", action: .empty),

                // Study Information
                TagRule(tagName: "StudyID", tagCode: "(0020,0010)", action: .empty),
                TagRule(tagName: "AccessionNumber", tagCode: "(0008,0050)", action: .empty),
                TagRule(tagName: "StudyDescription", tagCode: "(0008,1030)", action: .empty),
                TagRule(tagName: "SeriesDescription", tagCode: "(0008,103E)", action: .keep),

                // Device Information
                TagRule(tagName: "StationName", tagCode: "(0008,1010)", action: .empty),
                TagRule(tagName: "DeviceSerialNumber", tagCode: "(0018,1000)", action: .empty),
            ],
            dateShiftStrategy: .random,
            patientIDStrategy: .sequential,
            maintainPatientMapping: true,
            removePrivateTags: true,
            removeCurves: true,
            removeOverlays: true
        )
    }

    /// Research profile - balanced anonymization for research use
    static var researchProfile: AnonymizationProfile {
        AnonymizationProfile(
            name: "Research Profile",
            isBuiltIn: true,
            tagRules: [
                // Patient Information (keep demographics for research)
                TagRule(tagName: "PatientName", tagCode: "(0010,0010)", action: .replace, replacementValue: "RESEARCH_SUBJECT"),
                TagRule(tagName: "PatientID", tagCode: "(0010,0020)", action: .hash),
                TagRule(tagName: "PatientBirthDate", tagCode: "(0010,0030)", action: .empty),
                TagRule(tagName: "PatientSex", tagCode: "(0010,0040)", action: .keep),
                TagRule(tagName: "PatientAge", tagCode: "(0010,1010)", action: .keep),
                TagRule(tagName: "PatientWeight", tagCode: "(0010,1030)", action: .keep),

                // Remove direct identifiers
                TagRule(tagName: "PatientAddress", tagCode: "(0010,1040)", action: .remove),
                TagRule(tagName: "InstitutionName", tagCode: "(0008,0080)", action: .empty),
                TagRule(tagName: "ReferringPhysicianName", tagCode: "(0008,0090)", action: .empty),

                // Keep clinical information
                TagRule(tagName: "StudyDescription", tagCode: "(0008,1030)", action: .keep),
                TagRule(tagName: "SeriesDescription", tagCode: "(0008,103E)", action: .keep),
                TagRule(tagName: "Modality", tagCode: "(0008,0060)", action: .keep),
            ],
            dateShiftStrategy: .random,
            patientIDStrategy: .hash,
            maintainPatientMapping: true,
            removePrivateTags: false
        )
    }

    /// All built-in profiles
    static var builtInProfiles: [AnonymizationProfile] {
        [basicProfile, fullProfile, researchProfile]
    }
}

/// Result of an anonymization operation
struct AnonymizationResult: Sendable {
    let successCount: Int
    let failureCount: Int
    let processedFiles: [URL]
    let patientMappings: [String: String]  // Original ID -> Anonymized ID
    let errors: [String]

    var isSuccess: Bool {
        failureCount == 0 && successCount > 0
    }

    var summary: String {
        if isSuccess {
            return "\(successCount) file\(successCount == 1 ? "" : "s") anonymized successfully"
        } else {
            return "\(successCount) succeeded, \(failureCount) failed"
        }
    }
}

/// Patient ID mapping for maintaining consistency across anonymization
struct PatientIDMapping: Codable, Sendable {
    let originalID: String
    let anonymizedID: String
    let dateCreated: Date

    init(originalID: String, anonymizedID: String, dateCreated: Date = Date()) {
        self.originalID = originalID
        self.anonymizedID = anonymizedID
        self.dateCreated = dateCreated
    }
}

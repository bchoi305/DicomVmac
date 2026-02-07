//
//  DicomAnonymizationService.swift
//  DicomVmac
//
//  Service for DICOM anonymization with profile management and patient ID mapping.
//

import Foundation

/// Service for DICOM anonymization operations
final class DicomAnonymizationService: Sendable {

    private let database: DatabaseManager
    private let patientMappings = PatientMappingStore()

    init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Anonymization Operations

    /// Anonymize a single DICOM file
    func anonymizeFile(
        inputPath: String,
        outputPath: String,
        profile: AnonymizationProfile
    ) async throws {
        try await Task.detached {
            // Build configuration from profile
            var config = try self.buildConfiguration(from: profile, inputPath: inputPath)

            // Perform anonymization
            let status = db_anonymize_file(inputPath, outputPath, &config)

            guard status == DB_STATUS_OK else {
                throw AnonymizationError.operationFailed(path: inputPath)
            }
        }.value
    }

    /// Anonymize a DICOM file in-place
    func anonymizeFileInPlace(
        filePath: String,
        profile: AnonymizationProfile
    ) async throws {
        try await Task.detached {
            var config = try self.buildConfiguration(from: profile, inputPath: filePath)

            let status = db_anonymize_file_inplace(filePath, &config)

            guard status == DB_STATUS_OK else {
                throw AnonymizationError.operationFailed(path: filePath)
            }
        }.value
    }

    /// Anonymize multiple DICOM files
    func anonymizeFiles(
        files: [(input: String, output: String)],
        profile: AnonymizationProfile,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> AnonymizationResult {
        var successCount = 0
        var failureCount = 0
        var processedFiles: [URL] = []
        var errors: [String] = []

        for (index, filePair) in files.enumerated() {
            do {
                try await anonymizeFile(
                    inputPath: filePair.input,
                    outputPath: filePair.output,
                    profile: profile
                )
                processedFiles.append(URL(fileURLWithPath: filePair.output))
                successCount += 1
            } catch {
                failureCount += 1
                errors.append("\(filePair.input): \(error.localizedDescription)")
            }

            onProgress(index + 1, files.count)
        }

        return AnonymizationResult(
            successCount: successCount,
            failureCount: failureCount,
            processedFiles: processedFiles,
            patientMappings: patientMappings.getAllMappings(),
            errors: errors
        )
    }

    /// Anonymize all instances in a series
    func anonymizeSeries(
        seriesRowID: Int64,
        outputDirectory: URL,
        profile: AnonymizationProfile,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> AnonymizationResult {
        // Get all instances in series
        let instances = try database.fetchInstances(forSeries: seriesRowID)

        guard !instances.isEmpty else {
            throw AnonymizationError.noFiles
        }

        // Create output directory
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        // Build file pairs
        let filePairs = instances.map { instance in
            let outputFilename = URL(fileURLWithPath: instance.filePath).lastPathComponent
            let outputPath = outputDirectory.appendingPathComponent(outputFilename).path
            return (input: instance.filePath, output: outputPath)
        }

        return try await anonymizeFiles(
            files: filePairs,
            profile: profile,
            onProgress: onProgress
        )
    }

    // MARK: - Configuration Building

    private func buildConfiguration(
        from profile: AnonymizationProfile,
        inputPath: String
    ) throws -> DB_AnonymizationConfig {
        // Convert tag rules to C structs
        var cTagRules = profile.tagRules.map { rule -> DB_TagRule in
            var cRule = DB_TagRule()

            // Parse tag code (e.g., "(0010,0010)")
            let components = parseTagCode(rule.tagCode)
            cRule.group = components.group
            cRule.element = components.element

            // Convert action
            cRule.action = convertTagAction(rule.action)

            // Copy replacement value
            if let replacement = rule.replacementValue {
                withUnsafeMutableBytes(of: &cRule.replacementValue) { buffer in
                    let count = min(replacement.count, buffer.count - 1)
                    replacement.utf8.prefix(count).enumerated().forEach { index, byte in
                        buffer[index] = byte
                    }
                    buffer[count] = 0  // Null terminator
                }
            }

            return cRule
        }

        // Handle patient ID mapping for hash strategy
        if profile.patientIDStrategy == .hash {
            // Get original patient ID from file
            if let originalID = try? extractPatientID(from: inputPath) {
                let anonymizedID = patientMappings.getOrCreateMapping(
                    originalID: originalID,
                    strategy: profile.patientIDStrategy,
                    prefix: profile.patientIDPrefix
                )

                // Add rule to replace patient ID with mapped value
                var patientIDRule = DB_TagRule()
                patientIDRule.group = 0x0010
                patientIDRule.element = 0x0020
                patientIDRule.action = DB_TAG_ACTION_REPLACE

                withUnsafeMutableBytes(of: &patientIDRule.replacementValue) { buffer in
                    let count = min(anonymizedID.count, buffer.count - 1)
                    anonymizedID.utf8.prefix(count).enumerated().forEach { index, byte in
                        buffer[index] = byte
                    }
                    buffer[count] = 0
                }

                cTagRules.append(patientIDRule)
            }
        }

        // Calculate date shift days
        var dateShiftDays: Int32 = 0
        switch profile.dateShiftStrategy {
        case .none:
            dateShiftDays = 0
        case .random:
            // Use a consistent random shift per patient
            if let originalID = try? extractPatientID(from: inputPath) {
                dateShiftDays = Int32(patientMappings.getDateShift(forPatientID: originalID))
            }
        case .fixed:
            dateShiftDays = Int32(profile.dateShiftDays ?? 0)
        case .remove:
            dateShiftDays = -1
        }

        // Build configuration
        var config = DB_AnonymizationConfig()
        config.tagRules = UnsafeMutablePointer<DB_TagRule>.allocate(capacity: cTagRules.count)
        config.tagRuleCount = Int32(cTagRules.count)
        config.removePrivateTags = profile.removePrivateTags
        config.replaceStudyUID = profile.replaceStudyInstanceUID
        config.replaceSeriesUID = profile.replaceSeriesInstanceUID
        config.replaceSOPUID = profile.replaceSOPInstanceUID
        config.dateShiftDays = dateShiftDays

        // Copy tag rules
        for (index, rule) in cTagRules.enumerated() {
            config.tagRules[index] = rule
        }

        return config
    }

    // MARK: - Helper Methods

    private func parseTagCode(_ code: String) -> (group: UInt16, element: UInt16) {
        // Parse format: "(0010,0020)"
        let cleaned = code.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "")

        let parts = cleaned.split(separator: ",")
        guard parts.count == 2,
              let group = UInt16(parts[0], radix: 16),
              let element = UInt16(parts[1], radix: 16) else {
            return (0x0010, 0x0010)  // Default to PatientName
        }

        return (group, element)
    }

    private func convertTagAction(_ action: TagAction) -> DB_TagAction {
        switch action {
        case .remove: return DB_TAG_ACTION_REMOVE
        case .replace: return DB_TAG_ACTION_REPLACE
        case .hash: return DB_TAG_ACTION_HASH
        case .keep: return DB_TAG_ACTION_KEEP
        case .empty: return DB_TAG_ACTION_EMPTY
        case .generateUID: return DB_TAG_ACTION_GENERATE_UID
        }
    }

    private func extractPatientID(from filePath: String) throws -> String {
        // Extract patient ID from DICOM file
        var tags = DB_DicomTags()
        let status = db_extract_tags(filePath, &tags)

        guard status == DB_STATUS_OK else {
            return "UNKNOWN"
        }

        let patientID = withUnsafeBytes(of: &tags.patientID) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            return String(decoding: bytes, as: UTF8.self)
        }.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))

        return patientID.isEmpty ? "UNKNOWN" : patientID
    }
}

// MARK: - Patient Mapping Store

/// Thread-safe storage for patient ID mappings
final class PatientMappingStore: @unchecked Sendable {
    private var mappings: [String: String] = [:]
    private var dateShifts: [String: Int] = [:]
    private var sequentialCounter = 0
    private let lock = NSLock()

    func getOrCreateMapping(
        originalID: String,
        strategy: PatientIDMappingStrategy,
        prefix: String
    ) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let existing = mappings[originalID] {
            return existing
        }

        let anonymizedID: String
        switch strategy {
        case .sequential:
            sequentialCounter += 1
            anonymizedID = String(format: "%@%04d", prefix, sequentialCounter)

        case .hash:
            var hashOutput = [CChar](repeating: 0, count: 65)
            db_generate_hash(originalID, &hashOutput, 65)
            let fullHash = hashOutput.withUnsafeBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                return String(decoding: bytes, as: UTF8.self)
            }.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            // Use first 16 characters of hash
            anonymizedID = String(fullHash.prefix(16))

        case .custom:
            sequentialCounter += 1
            anonymizedID = String(format: "%@%04d", prefix, sequentialCounter)

        case .remove:
            anonymizedID = ""
        }

        mappings[originalID] = anonymizedID
        return anonymizedID
    }

    func getDateShift(forPatientID patientID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        if let existing = dateShifts[patientID] {
            return existing
        }

        // Generate random shift between -365 and +365 days
        let shift = Int.random(in: -365...365)
        dateShifts[patientID] = shift
        return shift
    }

    func getAllMappings() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return mappings
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        mappings.removeAll()
        dateShifts.removeAll()
        sequentialCounter = 0
    }
}

// MARK: - Errors

enum AnonymizationError: Error, LocalizedError {
    case operationFailed(path: String)
    case invalidProfile
    case noFiles
    case configurationError

    var errorDescription: String? {
        switch self {
        case .operationFailed(let path):
            return "Failed to anonymize file: \(path)"
        case .invalidProfile:
            return "Invalid anonymization profile"
        case .noFiles:
            return "No files to anonymize"
        case .configurationError:
            return "Failed to build anonymization configuration"
        }
    }
}

//
//  DicomNetworkService.swift
//  DicomVmac
//
//  High-level service for DICOM networking operations.
//  Wraps the bridge layer with error handling and database integration.
//

import Foundation

/// Service for DICOM networking operations (C-ECHO, C-FIND, C-MOVE, C-STORE)
final class DicomNetworkService: Sendable {

    private let bridge: DicomBridgeWrapper
    private let database: DatabaseManager
    private let localAE: String

    /// Initialize the network service
    /// - Parameters:
    ///   - bridge: DICOM bridge wrapper for C++ operations
    ///   - database: Database manager for storing retrieved studies
    ///   - localAE: Local Application Entity Title (default: "DICOMVMAC")
    init(
        bridge: DicomBridgeWrapper,
        database: DatabaseManager,
        localAE: String = "DICOMVMAC"
    ) {
        self.bridge = bridge
        self.database = database
        self.localAE = localAE
    }

    // MARK: - C-ECHO (Verification)

    /// Test connectivity to a PACS server using C-ECHO
    /// - Parameter node: PACS node to test
    /// - Throws: DicomNetworkError if connection fails
    func verifyConnection(to node: DicomNode) async throws {
        let result = try await bridge.echo(
            localAE: localAE,
            remoteNode: node
        )

        guard result.isSuccess else {
            throw DicomNetworkError.echoFailed(
                node: node,
                message: result.errorDescription ?? "Unknown error",
                dimseStatus: result.dimseStatus
            )
        }
    }

    // MARK: - C-FIND (Query)

    /// Query PACS for studies matching search criteria
    /// - Parameters:
    ///   - node: PACS node to query
    ///   - criteria: Search criteria (patient ID, name, date range, etc.)
    ///   - onResult: Callback invoked for each matching study
    /// - Returns: Number of studies found
    /// - Throws: DicomNetworkError if query fails
    func queryStudies(
        from node: DicomNode,
        criteria: DicomQueryCriteria,
        onResult: @escaping @Sendable (DicomTagData) -> Void
    ) async throws {
        // Validate criteria
        guard criteria.hasAnyCriteria else {
            throw DicomNetworkError.invalidCriteria(
                message: "At least one search criterion must be specified"
            )
        }

        let result = try await bridge.findStudies(
            localAE: localAE,
            remoteNode: node,
            criteria: criteria,
            onResult: onResult
        )

        guard result.isSuccess else {
            throw DicomNetworkError.queryFailed(
                node: node,
                message: result.errorDescription ?? "Unknown error",
                dimseStatus: result.dimseStatus
            )
        }
    }

    // MARK: - C-MOVE (Retrieve)

    /// Retrieve a study from PACS and import it to the local database
    /// - Parameters:
    ///   - node: PACS node to retrieve from
    ///   - studyInstanceUID: Study Instance UID to retrieve
    ///   - onProgress: Progress callback (completed, remaining, failed)
    /// - Returns: Number of instances successfully retrieved
    /// - Throws: DicomNetworkError if retrieval fails
    @discardableResult
    func retrieveStudy(
        from node: DicomNode,
        studyInstanceUID: String,
        onProgress: @escaping @Sendable (Int, Int, Int) -> Void
    ) async throws -> Int {
        // Validate study UID
        guard !studyInstanceUID.isEmpty else {
            throw DicomNetworkError.invalidStudyUID(
                message: "Study Instance UID cannot be empty"
            )
        }

        // Create temporary folder for retrieved files
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DicomRetrieve_\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(
                at: tempFolder,
                withIntermediateDirectories: true
            )
        } catch {
            throw DicomNetworkError.fileSystemError(
                message: "Failed to create temporary folder: \(error.localizedDescription)"
            )
        }

        // Perform C-MOVE
        let result = try await bridge.moveStudy(
            localAE: localAE,
            remoteNode: node,
            studyInstanceUID: studyInstanceUID,
            destinationFolder: tempFolder.path,
            onProgress: onProgress
        )

        guard result.isSuccess else {
            // Clean up temp folder
            try? FileManager.default.removeItem(at: tempFolder)

            throw DicomNetworkError.retrieveFailed(
                node: node,
                studyUID: studyInstanceUID,
                message: result.errorDescription ?? "Unknown error",
                dimseStatus: result.dimseStatus
            )
        }

        // Import retrieved files to database
        do {
            try await database.indexFolder(
                path: tempFolder.path,
                bridge: bridge,
                progress: { _, _ in }
            )

            // Clean up temp folder after successful import
            try? FileManager.default.removeItem(at: tempFolder)

            return 0

        } catch {
            // Clean up temp folder
            try? FileManager.default.removeItem(at: tempFolder)

            throw DicomNetworkError.importFailed(
                message: "Failed to import retrieved study: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - C-STORE (Send)

    /// Send DICOM files to a PACS server
    /// - Parameters:
    ///   - node: PACS node to send to
    ///   - filePaths: Array of DICOM file paths to send
    ///   - onProgress: Progress callback (completed, remaining, failed)
    /// - Returns: Number of files successfully sent
    /// - Throws: DicomNetworkError if send fails
    @discardableResult
    func sendStudy(
        to node: DicomNode,
        filePaths: [String],
        onProgress: @escaping @Sendable (Int, Int, Int) -> Void
    ) async throws -> Int {
        // Validate file paths
        guard !filePaths.isEmpty else {
            throw DicomNetworkError.invalidFilePaths(
                message: "No files to send"
            )
        }

        // Check that all files exist
        for path in filePaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw DicomNetworkError.invalidFilePaths(
                    message: "File not found: \(path)"
                )
            }
        }

        // Perform C-STORE
        let result = try await bridge.storeStudy(
            localAE: localAE,
            remoteNode: node,
            filePaths: filePaths,
            onProgress: onProgress
        )

        guard result.isSuccess else {
            throw DicomNetworkError.sendFailed(
                node: node,
                message: result.errorDescription ?? "Unknown error",
                dimseStatus: result.dimseStatus
            )
        }

        return 0
    }
}

// MARK: - Errors

/// Errors that can occur during DICOM networking operations
enum DicomNetworkError: Error, LocalizedError {
    case echoFailed(node: DicomNode, message: String, dimseStatus: Int)
    case queryFailed(node: DicomNode, message: String, dimseStatus: Int)
    case retrieveFailed(node: DicomNode, studyUID: String, message: String, dimseStatus: Int)
    case sendFailed(node: DicomNode, message: String, dimseStatus: Int)
    case invalidCriteria(message: String)
    case invalidStudyUID(message: String)
    case invalidFilePaths(message: String)
    case fileSystemError(message: String)
    case importFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .echoFailed(let node, let message, let status):
            return "Connection test failed to \(node.aeTitle)@\(node.hostname):\(node.port)\n\(message)\nDIMSE Status: 0x\(String(format: "%04X", status))"

        case .queryFailed(let node, let message, let status):
            return "Query failed for \(node.aeTitle)@\(node.hostname):\(node.port)\n\(message)\nDIMSE Status: 0x\(String(format: "%04X", status))"

        case .retrieveFailed(let node, let studyUID, let message, let status):
            return "Retrieve failed for study \(studyUID) from \(node.aeTitle)@\(node.hostname):\(node.port)\n\(message)\nDIMSE Status: 0x\(String(format: "%04X", status))"

        case .sendFailed(let node, let message, let status):
            return "Send failed to \(node.aeTitle)@\(node.hostname):\(node.port)\n\(message)\nDIMSE Status: 0x\(String(format: "%04X", status))"

        case .invalidCriteria(let message):
            return "Invalid search criteria: \(message)"

        case .invalidStudyUID(let message):
            return "Invalid study UID: \(message)"

        case .invalidFilePaths(let message):
            return "Invalid file paths: \(message)"

        case .fileSystemError(let message):
            return "File system error: \(message)"

        case .importFailed(let message):
            return "Import failed: \(message)"
        }
    }

    /// User-friendly title for error alerts
    var errorTitle: String {
        switch self {
        case .echoFailed:
            return "Connection Test Failed"
        case .queryFailed:
            return "Query Failed"
        case .retrieveFailed:
            return "Retrieve Failed"
        case .sendFailed:
            return "Send Failed"
        case .invalidCriteria, .invalidStudyUID, .invalidFilePaths:
            return "Invalid Input"
        case .fileSystemError:
            return "File System Error"
        case .importFailed:
            return "Import Failed"
        }
    }

    /// Suggested action for the user
    var recoverySuggestion: String? {
        switch self {
        case .echoFailed:
            return "Check that the PACS server is running, the AE Title is correct, and the network connection is working."

        case .queryFailed:
            return "Verify that the PACS server supports C-FIND and that your search criteria are valid."

        case .retrieveFailed:
            return "Ensure the PACS server supports C-MOVE and that the study exists. Check available disk space."

        case .sendFailed:
            return "Verify that the PACS server supports C-STORE and has enough storage space."

        case .invalidCriteria:
            return "Provide at least one search criterion (Patient ID, Name, Date, etc.)."

        case .invalidStudyUID:
            return "Ensure the Study Instance UID is valid and not empty."

        case .invalidFilePaths:
            return "Check that all file paths are valid and the files exist."

        case .fileSystemError:
            return "Check available disk space and file permissions."

        case .importFailed:
            return "Ensure the retrieved files are valid DICOM files and the database is accessible."
        }
    }
}

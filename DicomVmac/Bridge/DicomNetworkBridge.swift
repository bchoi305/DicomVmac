//
//  DicomNetworkBridge.swift
//  DicomVmac
//
//  Swift async wrappers for DICOM networking operations.
//

import Foundation

// MARK: - Network Result

/// Result from a DICOM network operation
struct DicomNetworkResult: Sendable {
    let status: DB_Status
    let errorMessage: String
    let dimseStatus: Int

    /// Check if the operation was successful
    var isSuccess: Bool {
        status == DB_STATUS_OK && dimseStatus == 0
    }

    /// User-friendly error description
    var errorDescription: String? {
        guard !isSuccess else { return nil }

        if !errorMessage.isEmpty {
            return errorMessage
        }

        switch status {
        case DB_STATUS_ERROR:
            return "Network operation failed (DIMSE: 0x\(String(format: "%04X", dimseStatus)))"
        case DB_STATUS_NOT_FOUND:
            return "Resource not found"
        case DB_STATUS_CANCELLED:
            return "Operation cancelled"
        case DB_STATUS_TIMEOUT:
            return "Operation timed out"
        default:
            return "Unknown error"
        }
    }
}

// MARK: - Network Bridge

extension DicomBridgeWrapper {

    // MARK: - C-ECHO (Verification)

    /// Test connectivity to a PACS server using C-ECHO
    /// - Parameters:
    ///   - localAE: Local Application Entity Title
    ///   - remoteNode: Remote PACS node configuration
    ///   - timeoutSeconds: Operation timeout (default: 10 seconds)
    /// - Returns: Network result indicating success or failure
    func echo(
        localAE: String,
        remoteNode: DicomNode,
        timeoutSeconds: Int = 10
    ) async throws -> DicomNetworkResult {
        try await Task.detached {
            // Convert Swift DicomNode to C DB_DicomNode
            var cNode = DB_DicomNode()
            withUnsafeMutablePointer(to: &cNode.aeTitle.0) { ptr in
                remoteNode.aeTitle.withCString { strncpy(ptr, $0, 16) }
            }
            withUnsafeMutablePointer(to: &cNode.hostname.0) { ptr in
                remoteNode.hostname.withCString { strncpy(ptr, $0, 255) }
            }
            cNode.port = Int32(remoteNode.port)

            // Call C function
            let cResult = localAE.withCString { localAEPtr in
                db_echo(localAEPtr, &cNode, Int32(timeoutSeconds))
            }

            // Convert C result to Swift
            let errorMsg = withUnsafePointer(to: cResult.errorMessage) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }

            return DicomNetworkResult(
                status: cResult.status,
                errorMessage: errorMsg,
                dimseStatus: Int(cResult.dimseStatus)
            )
        }.value
    }

    // MARK: - C-FIND (Query)

    /// Query PACS for studies matching criteria using C-FIND
    /// - Parameters:
    ///   - localAE: Local Application Entity Title
    ///   - remoteNode: Remote PACS node configuration
    ///   - criteria: Search criteria (DicomQueryCriteria)
    ///   - onResult: Callback invoked for each matching study
    ///   - timeoutSeconds: Operation timeout (default: 30 seconds)
    /// - Returns: Network result with match count
    func findStudies(
        localAE: String,
        remoteNode: DicomNode,
        criteria: DicomQueryCriteria,
        onResult: @escaping @Sendable (DicomTagData) -> Void,
        timeoutSeconds: Int = 30
    ) async throws -> DicomNetworkResult {
        try await Task.detached {
            // Convert Swift DicomNode to C DB_DicomNode
            var cNode = DB_DicomNode()
            withUnsafeMutablePointer(to: &cNode.aeTitle.0) { ptr in
                remoteNode.aeTitle.withCString { strncpy(ptr, $0, 16) }
            }
            withUnsafeMutablePointer(to: &cNode.hostname.0) { ptr in
                remoteNode.hostname.withCString { strncpy(ptr, $0, 255) }
            }
            cNode.port = Int32(remoteNode.port)

            // Convert Swift criteria to C DB_DicomTags
            var cCriteria = DB_DicomTags()

            if let patientID = criteria.patientID {
                withUnsafeMutablePointer(to: &cCriteria.patientID.0) { ptr in
                    patientID.withCString { strncpy(ptr, $0, 63) }
                }
            }

            if let patientName = criteria.patientName {
                withUnsafeMutablePointer(to: &cCriteria.patientName.0) { ptr in
                    patientName.withCString { strncpy(ptr, $0, 127) }
                }
            }

            if let dateRange = criteria.studyDate?.dicomRangeString {
                withUnsafeMutablePointer(to: &cCriteria.studyDate.0) { ptr in
                    dateRange.withCString { strncpy(ptr, $0, 15) }
                }
            }

            if let modality = criteria.modality {
                withUnsafeMutablePointer(to: &cCriteria.studyModality.0) { ptr in
                    modality.withCString { strncpy(ptr, $0, 15) }
                }
            }

            if let accessionNumber = criteria.accessionNumber {
                withUnsafeMutablePointer(to: &cCriteria.accessionNumber.0) { ptr in
                    accessionNumber.withCString { strncpy(ptr, $0, 63) }
                }
            }

            // Create callback context
            let context = QueryContext(onResult: onResult)
            let contextPtr = Unmanaged.passRetained(context).toOpaque()
            defer { Unmanaged<QueryContext>.fromOpaque(contextPtr).release() }

            // C callback function
            let cCallback: DB_QueryCallback = { userData, tagsPtr in
                guard let userData = userData, let tagsPtr = tagsPtr else { return }

                let context = Unmanaged<QueryContext>.fromOpaque(userData)
                    .takeUnretainedValue()

                // Convert C tags to Swift
                let tagData = DicomTagData.from(tagsPtr: tagsPtr, filePath: "")

                // Invoke user callback
                context.onResult(tagData)
            }

            // Call C function
            let cResult = localAE.withCString { localAEPtr in
                db_find_studies(
                    localAEPtr,
                    &cNode,
                    &cCriteria,
                    cCallback,
                    contextPtr,
                    Int32(timeoutSeconds)
                )
            }

            // Convert C result to Swift
            let errorMsg = withUnsafePointer(to: cResult.errorMessage) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }

            return DicomNetworkResult(
                status: cResult.status,
                errorMessage: errorMsg,
                dimseStatus: Int(cResult.dimseStatus)
            )
        }.value
    }

    // MARK: - C-MOVE (Retrieve)

    /// Retrieve a study from PACS using C-MOVE
    /// - Parameters:
    ///   - localAE: Local Application Entity Title (also used as move destination)
    ///   - remoteNode: Remote PACS node configuration
    ///   - studyInstanceUID: Study to retrieve
    ///   - destinationFolder: Local folder to store retrieved files
    ///   - onProgress: Callback for progress updates (completed, remaining, failed)
    ///   - timeoutSeconds: Operation timeout (default: 300 seconds)
    /// - Returns: Network result with transfer statistics
    func moveStudy(
        localAE: String,
        remoteNode: DicomNode,
        studyInstanceUID: String,
        destinationFolder: String,
        onProgress: @escaping @Sendable (Int, Int, Int) -> Void,
        timeoutSeconds: Int = 300
    ) async throws -> DicomNetworkResult {
        try await Task.detached {
            // Convert Swift DicomNode to C DB_DicomNode
            var cNode = DB_DicomNode()
            withUnsafeMutablePointer(to: &cNode.aeTitle.0) { ptr in
                remoteNode.aeTitle.withCString { strncpy(ptr, $0, 16) }
            }
            withUnsafeMutablePointer(to: &cNode.hostname.0) { ptr in
                remoteNode.hostname.withCString { strncpy(ptr, $0, 255) }
            }
            cNode.port = Int32(remoteNode.port)

            // Create callback context
            let context = ProgressContext(onProgress: onProgress)
            let contextPtr = Unmanaged.passRetained(context).toOpaque()
            defer { Unmanaged<ProgressContext>.fromOpaque(contextPtr).release() }

            // C callback function
            let cCallback: DB_MoveProgressCallback = { userData, completed, remaining, failed in
                guard let userData = userData else { return }

                let context = Unmanaged<ProgressContext>.fromOpaque(userData)
                    .takeUnretainedValue()

                context.onProgress(
                    Int(completed),
                    Int(remaining),
                    Int(failed)
                )
            }

            // Call C function
            let cResult = localAE.withCString { localAEPtr in
                studyInstanceUID.withCString { studyUIDPtr in
                    destinationFolder.withCString { destPtr in
                        db_move_study(
                            localAEPtr,
                            &cNode,
                            studyUIDPtr,
                            destPtr,
                            cCallback,
                            contextPtr,
                            Int32(timeoutSeconds)
                        )
                    }
                }
            }

            // Convert C result to Swift
            let errorMsg = withUnsafePointer(to: cResult.errorMessage) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }

            return DicomNetworkResult(
                status: cResult.status,
                errorMessage: errorMsg,
                dimseStatus: Int(cResult.dimseStatus)
            )
        }.value
    }

    // MARK: - C-STORE (Send)

    /// Send study to PACS using C-STORE
    /// - Parameters:
    ///   - localAE: Local Application Entity Title
    ///   - remoteNode: Remote PACS node configuration
    ///   - filePaths: Array of DICOM file paths to send
    ///   - onProgress: Callback for progress updates (completed, remaining, failed)
    ///   - timeoutSeconds: Operation timeout (default: 300 seconds)
    /// - Returns: Network result with transfer statistics
    func storeStudy(
        localAE: String,
        remoteNode: DicomNode,
        filePaths: [String],
        onProgress: @escaping @Sendable (Int, Int, Int) -> Void,
        timeoutSeconds: Int = 300
    ) async throws -> DicomNetworkResult {
        try await Task.detached {
            // Convert Swift DicomNode to C DB_DicomNode
            var cNode = DB_DicomNode()
            withUnsafeMutablePointer(to: &cNode.aeTitle.0) { ptr in
                remoteNode.aeTitle.withCString { strncpy(ptr, $0, 16) }
            }
            withUnsafeMutablePointer(to: &cNode.hostname.0) { ptr in
                remoteNode.hostname.withCString { strncpy(ptr, $0, 255) }
            }
            cNode.port = Int32(remoteNode.port)

            // Convert file paths to C string array
            let cStrings = filePaths.map { $0.withCString { strdup($0) } }
            defer { cStrings.forEach { free($0) } }

            // Convert mutable pointers to const pointers
            let constPtrs: [UnsafePointer<CChar>?] = cStrings.map { ptr in
                ptr.map { UnsafePointer($0) }
            }

            // Create callback context
            let context = ProgressContext(onProgress: onProgress)
            let contextPtr = Unmanaged.passRetained(context).toOpaque()
            defer { Unmanaged<ProgressContext>.fromOpaque(contextPtr).release() }

            // C callback function
            let cCallback: DB_MoveProgressCallback = { userData, completed, remaining, failed in
                guard let userData = userData else { return }

                let context = Unmanaged<ProgressContext>.fromOpaque(userData)
                    .takeUnretainedValue()

                context.onProgress(
                    Int(completed),
                    Int(remaining),
                    Int(failed)
                )
            }

            // Call C function
            let cResult = localAE.withCString { localAEPtr in
                constPtrs.withUnsafeBufferPointer { buffer in
                    db_store_study(
                        localAEPtr,
                        &cNode,
                        buffer.baseAddress,
                        Int32(filePaths.count),
                        cCallback,
                        contextPtr,
                        Int32(timeoutSeconds)
                    )
                }
            }

            // Convert C result to Swift
            let errorMsg = withUnsafePointer(to: cResult.errorMessage) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }

            return DicomNetworkResult(
                status: cResult.status,
                errorMessage: errorMsg,
                dimseStatus: Int(cResult.dimseStatus)
            )
        }.value
    }
}

// MARK: - Callback Contexts

/// Context for C-FIND query callbacks
private final class QueryContext: @unchecked Sendable {
    let onResult: @Sendable (DicomTagData) -> Void

    init(onResult: @escaping @Sendable (DicomTagData) -> Void) {
        self.onResult = onResult
    }
}

/// Context for C-MOVE/C-STORE progress callbacks
private final class ProgressContext: @unchecked Sendable {
    let onProgress: @Sendable (Int, Int, Int) -> Void

    init(onProgress: @escaping @Sendable (Int, Int, Int) -> Void) {
        self.onProgress = onProgress
    }
}

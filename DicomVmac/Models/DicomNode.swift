//
//  DicomNode.swift
//  DicomVmac
//
//  Represents a DICOM network node (PACS server or SCP) configuration.
//

import Foundation
import GRDB

/// Represents a DICOM network node (PACS server or SCP) for query/retrieve operations.
struct DicomNode: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {

    var id: Int64?

    /// Application Entity Title (max 16 characters)
    var aeTitle: String

    /// Hostname or IP address
    var hostname: String

    /// DICOM port (typically 104)
    var port: Int

    /// User-friendly description
    var description: String?

    /// Supports C-FIND/C-MOVE query/retrieve operations
    var isQueryRetrieve: Bool

    /// Supports C-STORE storage operations
    var isStorage: Bool

    /// Whether this node is active/enabled
    var isActive: Bool

    static let databaseTableName = "dicom_node"

    /// Called after successful insertion to set the auto-generated ID
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Validate the node configuration
    func validate() throws {
        guard !aeTitle.isEmpty, aeTitle.count <= 16 else {
            throw DicomNodeError.invalidAETitle
        }

        guard !hostname.isEmpty else {
            throw DicomNodeError.invalidHostname
        }

        guard port > 0, port <= 65535 else {
            throw DicomNodeError.invalidPort
        }

        guard isQueryRetrieve || isStorage else {
            throw DicomNodeError.noCapabilities
        }
    }
}

/// Errors related to DICOM node configuration
enum DicomNodeError: Error, LocalizedError {
    case invalidAETitle
    case invalidHostname
    case invalidPort
    case noCapabilities

    var errorDescription: String? {
        switch self {
        case .invalidAETitle:
            return "AE Title must be 1-16 characters"
        case .invalidHostname:
            return "Hostname cannot be empty"
        case .invalidPort:
            return "Port must be between 1 and 65535"
        case .noCapabilities:
            return "Node must support at least Query/Retrieve or Storage"
        }
    }
}

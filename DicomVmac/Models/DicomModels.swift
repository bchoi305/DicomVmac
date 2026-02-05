//
//  DicomModels.swift
//  DicomVmac
//
//  Data models for DICOM entities. Conforming to GRDB protocols
//  for SQLite persistence.
//

import Foundation
import GRDB

/// Represents a DICOM Patient entity.
struct Patient: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var patientID: String
    var patientName: String
    var birthDate: String?

    static let databaseTableName = "patient"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Represents a DICOM Study entity.
struct Study: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var studyInstanceUID: String
    var patientRowID: Int64
    var studyDate: String?
    var studyDescription: String?
    var accessionNumber: String?
    var modality: String?

    static let databaseTableName = "study"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Represents a DICOM Series entity.
struct Series: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var seriesInstanceUID: String
    var studyRowID: Int64
    var seriesNumber: Int?
    var seriesDescription: String?
    var modality: String?
    var instanceCount: Int

    static let databaseTableName = "series"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Represents a single DICOM Instance (image file).
struct Instance: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var sopInstanceUID: String
    var seriesRowID: Int64
    var instanceNumber: Int?
    var filePath: String
    var rows: Int?
    var columns: Int?
    var bitsAllocated: Int?

    static let databaseTableName = "instance"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

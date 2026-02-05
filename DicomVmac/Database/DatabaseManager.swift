//
//  DatabaseManager.swift
//  DicomVmac
//
//  Manages the SQLite database via GRDB for DICOM study indexing.
//

import Foundation
import GRDB

/// Thread-safe database manager for the DICOM index.
final class DatabaseManager: Sendable {

    /// Shared database queue (thread-safe).
    let dbQueue: DatabaseQueue

    /// Initialize with a database file path. Creates the schema if needed.
    /// - Parameter path: Path to the SQLite database file.
    ///                   Pass nil for an in-memory database (testing).
    init(path: String? = nil) throws {
        if let path = path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try migrate()
    }

    // MARK: - Schema Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            try db.create(table: "patient", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("patientID", .text).notNull()
                t.column("patientName", .text).notNull()
                t.column("birthDate", .text)
                t.uniqueKey(["patientID"])
            }

            try db.create(table: "study", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("studyInstanceUID", .text).notNull().unique()
                t.column("patientRowID", .integer)
                    .notNull()
                    .references("patient", onDelete: .cascade)
                t.column("studyDate", .text)
                t.column("studyDescription", .text)
                t.column("accessionNumber", .text)
                t.column("modality", .text)
            }

            try db.create(table: "series", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("seriesInstanceUID", .text).notNull().unique()
                t.column("studyRowID", .integer)
                    .notNull()
                    .references("study", onDelete: .cascade)
                t.column("seriesNumber", .integer)
                t.column("seriesDescription", .text)
                t.column("modality", .text)
                t.column("instanceCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "instance", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sopInstanceUID", .text).notNull().unique()
                t.column("seriesRowID", .integer)
                    .notNull()
                    .references("series", onDelete: .cascade)
                t.column("instanceNumber", .integer)
                t.column("filePath", .text).notNull()
                t.column("rows", .integer)
                t.column("columns", .integer)
                t.column("bitsAllocated", .integer)
            }

            // Indices for common queries
            try db.create(indexOn: "study", columns: ["patientRowID"])
            try db.create(indexOn: "series", columns: ["studyRowID"])
            try db.create(indexOn: "instance", columns: ["seriesRowID"])
            try db.create(indexOn: "instance", columns: ["filePath"])
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Insert / Upsert

    /// Insert a DICOM file's tags into the database (upserts Patient, Study, Series;
    /// inserts Instance). Runs in a single transaction.
    func insertFromTags(_ tags: DicomTagData) throws {
        try dbQueue.write { db in
            // Upsert Patient
            let patientID = tags.patientID.isEmpty ? "UNKNOWN" : tags.patientID
            let patientName = tags.patientName.isEmpty ? "Unknown" : tags.patientName
            let patientRowID: Int64
            if let existing = try Patient.filter(Column("patientID") == patientID).fetchOne(db) {
                patientRowID = existing.id!
            } else {
                var p = Patient(
                    patientID: patientID,
                    patientName: patientName,
                    birthDate: tags.birthDate.isEmpty ? nil : tags.birthDate
                )
                try p.insert(db)
                patientRowID = db.lastInsertedRowID
            }

            // Upsert Study
            let studyUID = tags.studyInstanceUID
            guard !studyUID.isEmpty else { return }
            let studyRowID: Int64
            if let existing = try Study.filter(Column("studyInstanceUID") == studyUID).fetchOne(db) {
                studyRowID = existing.id!
            } else {
                var s = Study(
                    studyInstanceUID: studyUID,
                    patientRowID: patientRowID,
                    studyDate: tags.studyDate.isEmpty ? nil : tags.studyDate,
                    studyDescription: tags.studyDescription.isEmpty
                        ? nil : tags.studyDescription,
                    accessionNumber: tags.accessionNumber.isEmpty
                        ? nil : tags.accessionNumber,
                    modality: tags.studyModality.isEmpty ? nil : tags.studyModality
                )
                try s.insert(db)
                studyRowID = db.lastInsertedRowID
            }

            // Upsert Series
            let seriesUID = tags.seriesInstanceUID
            guard !seriesUID.isEmpty else { return }
            let seriesRowID: Int64
            if let existing = try Series.filter(
                Column("seriesInstanceUID") == seriesUID).fetchOne(db) {
                seriesRowID = existing.id!
            } else {
                var sr = Series(
                    seriesInstanceUID: seriesUID,
                    studyRowID: studyRowID,
                    seriesNumber: tags.seriesNumber > 0 ? tags.seriesNumber : nil,
                    seriesDescription: tags.seriesDescription.isEmpty
                        ? nil : tags.seriesDescription,
                    modality: tags.seriesModality.isEmpty ? nil : tags.seriesModality,
                    instanceCount: 0
                )
                try sr.insert(db)
                seriesRowID = db.lastInsertedRowID
            }

            // Insert Instance (skip duplicates)
            let sopUID = tags.sopInstanceUID
            guard !sopUID.isEmpty else { return }
            let exists = try Instance.filter(
                Column("sopInstanceUID") == sopUID).fetchCount(db) > 0
            if !exists {
                var instance = Instance(
                    sopInstanceUID: sopUID,
                    seriesRowID: seriesRowID,
                    instanceNumber: tags.instanceNumber > 0 ? tags.instanceNumber : nil,
                    filePath: tags.filePath,
                    rows: tags.rows > 0 ? tags.rows : nil,
                    columns: tags.columns > 0 ? tags.columns : nil,
                    bitsAllocated: tags.bitsAllocated > 0 ? tags.bitsAllocated : nil
                )
                try instance.insert(db)

                // Update instance count on series
                let count = try Instance.filter(
                    Column("seriesRowID") == seriesRowID).fetchCount(db)
                try db.execute(
                    sql: "UPDATE series SET instanceCount = ? WHERE id = ?",
                    arguments: [count, seriesRowID])
            }
        }
    }

    /// Index a folder by scanning for DICOM files and inserting into database.
    func indexFolder(
        path: String,
        bridge: DicomBridgeWrapper,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        try await Task.detached { [self] in
            try bridge.scanFolder(
                path: path,
                onFile: { [self] tagData in
                    do {
                        try self.insertFromTags(tagData)
                    } catch {
                        NSLog("[DatabaseManager] Insert failed: %@",
                              error.localizedDescription)
                    }
                },
                onProgress: { scanned, found in
                    progress(scanned, found)
                }
            )
        }.value
    }

    // MARK: - Queries

    func fetchPatients() throws -> [Patient] {
        try dbQueue.read { db in
            try Patient.order(Column("patientName")).fetchAll(db)
        }
    }

    func fetchStudies(forPatient patientRowID: Int64) throws -> [Study] {
        try dbQueue.read { db in
            try Study
                .filter(Column("patientRowID") == patientRowID)
                .order(Column("studyDate").desc)
                .fetchAll(db)
        }
    }

    func fetchSeries(forStudy studyRowID: Int64) throws -> [Series] {
        try dbQueue.read { db in
            try Series
                .filter(Column("studyRowID") == studyRowID)
                .order(Column("seriesNumber"))
                .fetchAll(db)
        }
    }

    func fetchInstances(forSeries seriesRowID: Int64) throws -> [Instance] {
        try dbQueue.read { db in
            try Instance
                .filter(Column("seriesRowID") == seriesRowID)
                .order(Column("instanceNumber"))
                .fetchAll(db)
        }
    }
}

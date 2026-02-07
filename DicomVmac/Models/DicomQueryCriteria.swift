//
//  DicomQueryCriteria.swift
//  DicomVmac
//
//  Search criteria for DICOM C-FIND queries.
//

import Foundation

/// Search criteria for querying PACS servers (C-FIND at STUDY level).
struct DicomQueryCriteria: Sendable {

    /// Patient ID (exact match or wildcard with *)
    var patientID: String?

    /// Patient name (exact match or wildcard with *)
    var patientName: String?

    /// Study date range
    var studyDate: DateRange?

    /// Modality (e.g., CT, MR, CR)
    var modality: String?

    /// Accession number
    var accessionNumber: String?

    /// Date range for study date filtering
    struct DateRange: Sendable {
        /// Start date in YYYYMMDD format
        var from: String?

        /// End date in YYYYMMDD format
        var to: String?

        /// Create a DICOM date range string (YYYYMMDD-YYYYMMDD)
        var dicomRangeString: String? {
            switch (from, to) {
            case (.some(let f), .some(let t)):
                return "\(f)-\(t)"
            case (.some(let f), .none):
                return "\(f)-"
            case (.none, .some(let t)):
                return "-\(t)"
            case (.none, .none):
                return nil
            }
        }
    }

    /// Check if any search criteria is specified
    var hasAnyCriteria: Bool {
        patientID != nil ||
        patientName != nil ||
        studyDate != nil ||
        modality != nil ||
        accessionNumber != nil
    }
}

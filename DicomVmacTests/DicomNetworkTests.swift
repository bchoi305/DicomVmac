//
//  DicomNetworkTests.swift
//  DicomVmacTests
//
//  Tests for DICOM networking functionality.
//

import Testing
@testable import DicomVmac

@Suite("DICOM Network Tests")
struct DicomNetworkTests {

    // MARK: - DicomNode Validation Tests

    @Test("DicomNode validates AE Title length")
    func validateAETitleLength() throws {
        // Valid AE Title (16 chars max)
        var validNode = DicomNode(
            id: nil,
            aeTitle: "VALIDAETITLE",
            hostname: "localhost",
            port: 104,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )
        #expect(throws: Never.self) {
            try validNode.validate()
        }

        // AE Title too long (17 chars)
        var invalidNode = DicomNode(
            id: nil,
            aeTitle: "TOOLONGAETITLE123",
            hostname: "localhost",
            port: 104,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )
        #expect(throws: DicomNodeError.invalidAETitle) {
            try invalidNode.validate()
        }

        // Empty AE Title
        var emptyNode = DicomNode(
            id: nil,
            aeTitle: "",
            hostname: "localhost",
            port: 104,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )
        #expect(throws: DicomNodeError.invalidAETitle) {
            try emptyNode.validate()
        }
    }

    @Test("DicomNode validates hostname")
    func validateHostname() throws {
        var invalidNode = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "",
            port: 104,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )

        #expect(throws: DicomNodeError.invalidHostname) {
            try invalidNode.validate()
        }
    }

    @Test("DicomNode validates port range")
    func validatePortRange() throws {
        // Port too low
        var lowPortNode = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 0,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )
        #expect(throws: DicomNodeError.invalidPort) {
            try lowPortNode.validate()
        }

        // Port too high
        var highPortNode = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 65536,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )
        #expect(throws: DicomNodeError.invalidPort) {
            try highPortNode.validate()
        }

        // Valid port
        var validNode = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 104,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )
        #expect(throws: Never.self) {
            try validNode.validate()
        }
    }

    @Test("DicomNode requires at least one capability")
    func validateCapabilities() throws {
        var noCapabilitiesNode = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 104,
            description: "Test",
            isQueryRetrieve: false,
            isStorage: false,
            isActive: true
        )

        #expect(throws: DicomNodeError.noCapabilities) {
            try noCapabilitiesNode.validate()
        }

        // At least Query/Retrieve
        var qrNode = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 104,
            description: "Test",
            isQueryRetrieve: true,
            isStorage: false,
            isActive: true
        )
        #expect(throws: Never.self) {
            try qrNode.validate()
        }

        // At least Storage
        var storageNode = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 104,
            description: "Test",
            isQueryRetrieve: false,
            isStorage: true,
            isActive: true
        )
        #expect(throws: Never.self) {
            try storageNode.validate()
        }
    }

    // MARK: - Database CRUD Tests

    @Test("Database can insert and fetch DicomNode")
    func databaseInsertFetch() async throws {
        // Create in-memory database
        let db = try DatabaseManager(path: nil)

        var node = DicomNode(
            id: nil,
            aeTitle: "TESTPACS",
            hostname: "pacs.example.com",
            port: 11112,
            description: "Test PACS",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )

        // Insert
        let insertedID = try db.insertDicomNode(node)
        #expect(insertedID > 0)

        // Fetch
        let nodes = try db.fetchDicomNodes()
        #expect(nodes.count == 1)
        #expect(nodes[0].aeTitle == "TESTPACS")
        #expect(nodes[0].hostname == "pacs.example.com")
        #expect(nodes[0].port == 11112)
        #expect(nodes[0].description == "Test PACS")
        #expect(nodes[0].isQueryRetrieve == true)
        #expect(nodes[0].isStorage == true)
        #expect(nodes[0].isActive == true)
    }

    @Test("Database can update DicomNode")
    func databaseUpdate() async throws {
        let db = try DatabaseManager(path: nil)

        var node = DicomNode(
            id: nil,
            aeTitle: "ORIGINAL",
            hostname: "original.example.com",
            port: 104,
            description: "Original",
            isQueryRetrieve: true,
            isStorage: false,
            isActive: true
        )

        let insertedID = try db.insertDicomNode(node)
        node.id = insertedID

        // Update
        node.aeTitle = "UPDATED"
        node.hostname = "updated.example.com"
        node.port = 11112
        node.description = "Updated"
        node.isStorage = true
        node.isActive = false

        try db.updateDicomNode(node)

        // Fetch and verify
        let nodes = try db.fetchDicomNodes()
        #expect(nodes.count == 1)
        #expect(nodes[0].aeTitle == "UPDATED")
        #expect(nodes[0].hostname == "updated.example.com")
        #expect(nodes[0].port == 11112)
        #expect(nodes[0].description == "Updated")
        #expect(nodes[0].isStorage == true)
        #expect(nodes[0].isActive == false)
    }

    @Test("Database can delete DicomNode")
    func databaseDelete() async throws {
        let db = try DatabaseManager(path: nil)

        var node = DicomNode(
            id: nil,
            aeTitle: "TODELETE",
            hostname: "localhost",
            port: 104,
            description: "To Delete",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )

        let insertedID = try db.insertDicomNode(node)

        // Verify inserted
        var nodes = try db.fetchDicomNodes()
        #expect(nodes.count == 1)

        // Delete
        try db.deleteDicomNode(id: insertedID)

        // Verify deleted
        nodes = try db.fetchDicomNodes()
        #expect(nodes.count == 0)
    }

    @Test("Database enforces unique constraint on AE Title + Hostname + Port")
    func databaseUniqueConstraint() async throws {
        let db = try DatabaseManager(path: nil)

        let node1 = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 104,
            description: "First",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )

        let node2 = DicomNode(
            id: nil,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 104,
            description: "Second (duplicate)",
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )

        // Insert first node
        _ = try db.insertDicomNode(node1)

        // Attempt to insert duplicate should fail
        #expect(throws: Error.self) {
            try db.insertDicomNode(node2)
        }
    }

    // MARK: - DicomQueryCriteria Tests

    @Test("DicomQueryCriteria detects when no criteria specified")
    func queryCriteriaEmpty() {
        let emptyCriteria = DicomQueryCriteria()
        #expect(emptyCriteria.hasAnyCriteria == false)
    }

    @Test("DicomQueryCriteria detects when criteria specified")
    func queryCriteriaHasData() {
        var criteria = DicomQueryCriteria()
        criteria.patientID = "12345"
        #expect(criteria.hasAnyCriteria == true)

        criteria = DicomQueryCriteria()
        criteria.patientName = "Smith^John"
        #expect(criteria.hasAnyCriteria == true)

        criteria = DicomQueryCriteria()
        criteria.modality = "CT"
        #expect(criteria.hasAnyCriteria == true)

        criteria = DicomQueryCriteria()
        criteria.accessionNumber = "ACC123"
        #expect(criteria.hasAnyCriteria == true)

        criteria = DicomQueryCriteria()
        criteria.studyDate = DicomQueryCriteria.DateRange(from: "20240101", to: "20240131")
        #expect(criteria.hasAnyCriteria == true)
    }

    @Test("DicomQueryCriteria DateRange formats correctly")
    func dateRangeFormatting() {
        // Both from and to
        var dateRange = DicomQueryCriteria.DateRange(from: "20240101", to: "20240131")
        #expect(dateRange.dicomRangeString == "20240101-20240131")

        // Only from
        dateRange = DicomQueryCriteria.DateRange(from: "20240101", to: nil)
        #expect(dateRange.dicomRangeString == "20240101-")

        // Only to
        dateRange = DicomQueryCriteria.DateRange(from: nil, to: "20240131")
        #expect(dateRange.dicomRangeString == "-20240131")

        // Neither
        dateRange = DicomQueryCriteria.DateRange(from: nil, to: nil)
        #expect(dateRange.dicomRangeString == nil)
    }

    // MARK: - DicomNetworkError Tests

    @Test("DicomNetworkError provides user-friendly descriptions")
    func errorDescriptions() {
        let node = DicomNode(
            id: 1,
            aeTitle: "TESTAE",
            hostname: "localhost",
            port: 104,
            description: nil,
            isQueryRetrieve: true,
            isStorage: true,
            isActive: true
        )

        let echoError = DicomNetworkError.echoFailed(
            node: node,
            message: "Connection refused",
            dimseStatus: 0x0001
        )
        #expect(echoError.localizedDescription.contains("TESTAE"))
        #expect(echoError.localizedDescription.contains("localhost"))
        #expect(echoError.errorTitle == "Connection Test Failed")
        #expect(echoError.recoverySuggestion != nil)

        let queryError = DicomNetworkError.queryFailed(
            node: node,
            message: "Timeout",
            dimseStatus: 0x0122
        )
        #expect(queryError.errorTitle == "Query Failed")

        let retrieveError = DicomNetworkError.retrieveFailed(
            node: node,
            studyUID: "1.2.3.4.5",
            message: "Transfer failed",
            dimseStatus: 0x0210
        )
        #expect(retrieveError.errorTitle == "Retrieve Failed")
        #expect(retrieveError.localizedDescription.contains("1.2.3.4.5"))

        let criteriaError = DicomNetworkError.invalidCriteria(
            message: "No criteria provided"
        )
        #expect(criteriaError.errorTitle == "Invalid Input")
    }

    // MARK: - Integration Test Notes

    /*
     Integration tests requiring a real PACS server:

     1. C-ECHO connectivity test
        - Start a test PACS: dcmtk's storescp -aet TESTPACS 11112
        - Test successful echo
        - Test failed echo (wrong port, wrong AE, etc.)

     2. C-FIND query test
        - Populate test PACS with sample data
        - Test query with various criteria
        - Test query with no matches
        - Test query with wildcards

     3. C-MOVE retrieve test
        - Query for a study
        - Retrieve the study
        - Verify files downloaded
        - Verify database updated

     4. C-STORE send test
        - Send DICOM files to PACS
        - Verify successful transfer
        - Test with invalid files

     5. Error scenarios
        - Connection timeout
        - Association rejection
        - Invalid DIMSE responses
        - Network interruption during transfer

     To run integration tests:
     1. Install DCMTK: brew install dcmtk
     2. Start test SCP: storescp -v -aet TESTPACS 11112
     3. Run tests with integration tests enabled
     */
}

//
//  DicomVmacTests.swift
//  DicomVmacTests
//

import Testing
@testable import DicomVmac

@Suite("DicomCore Bridge Tests")
struct DicomCoreBridgeTests {

    @Test("DicomCore version returns non-empty string")
    func versionIsNotEmpty() {
        let version = String(cString: db_version())
        #expect(!version.isEmpty)
        #expect(version.contains("DicomCore"))
    }

    @Test("Decode test frame returns valid dimensions")
    func decodeTestFrame() {
        var frame = DB_Frame16()
        let status = db_decode_frame16(nil, 0, &frame)

        #expect(status == DB_STATUS_OK)
        #expect(frame.width == 256)
        #expect(frame.height == 256)
        #expect(frame.bitsStored == 12)

        if let pixels = frame.pixels {
            db_free_buffer(pixels)
        }
    }

    @Test("Extract tags from non-existent file returns NOT_FOUND")
    func extractTagsMissingFile() {
        var tags = DB_DicomTags()
        let status = db_extract_tags("/nonexistent/file.dcm", &tags)
        #expect(status == DB_STATUS_NOT_FOUND)
    }

    @Test("Extract tags with null path returns ERROR")
    func extractTagsNullPath() {
        var tags = DB_DicomTags()
        let status = db_extract_tags(nil, &tags)
        #expect(status == DB_STATUS_ERROR)
    }

    @Test("Scan folder with non-existent path returns NOT_FOUND")
    func scanFolderMissingPath() {
        let status = db_scan_folder("/nonexistent/folder", { _, _, _ in }, nil, nil)
        #expect(status == DB_STATUS_NOT_FOUND)
    }
}

@Suite("Database Manager Tests")
struct DatabaseManagerTests {

    @Test("Database initializes with schema")
    func initDatabase() throws {
        let dbManager = try DatabaseManager(path: nil)
        try dbManager.dbQueue.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            #expect(tables.contains("patient"))
            #expect(tables.contains("study"))
            #expect(tables.contains("series"))
            #expect(tables.contains("instance"))
        }
    }

    @Test("Insert and query round-trip")
    func insertAndQuery() throws {
        let dbManager = try DatabaseManager(path: nil)

        let tags = DicomTagData(
            filePath: "/test/image.dcm",
            patientID: "PAT001",
            patientName: "Test Patient",
            birthDate: "19800101",
            studyInstanceUID: "1.2.3.4.5",
            studyDate: "20240101",
            studyDescription: "CT Chest",
            accessionNumber: "ACC001",
            studyModality: "CT",
            seriesInstanceUID: "1.2.3.4.5.1",
            seriesNumber: 1,
            seriesDescription: "Axial",
            seriesModality: "CT",
            sopInstanceUID: "1.2.3.4.5.1.1",
            instanceNumber: 1,
            rows: 512,
            columns: 512,
            bitsAllocated: 16
        )

        try dbManager.insertFromTags(tags)

        let patients = try dbManager.fetchPatients()
        #expect(patients.count == 1)
        #expect(patients[0].patientID == "PAT001")
        #expect(patients[0].patientName == "Test Patient")

        let studies = try dbManager.fetchStudies(forPatient: patients[0].id!)
        #expect(studies.count == 1)
        #expect(studies[0].studyInstanceUID == "1.2.3.4.5")

        let series = try dbManager.fetchSeries(forStudy: studies[0].id!)
        #expect(series.count == 1)
        #expect(series[0].seriesInstanceUID == "1.2.3.4.5.1")
        #expect(series[0].instanceCount == 1)

        let instances = try dbManager.fetchInstances(forSeries: series[0].id!)
        #expect(instances.count == 1)
        #expect(instances[0].filePath == "/test/image.dcm")
        #expect(instances[0].rows == 512)
    }

    @Test("Duplicate insert is idempotent")
    func duplicateInsert() throws {
        let dbManager = try DatabaseManager(path: nil)

        let tags = DicomTagData(
            filePath: "/test/image.dcm",
            patientID: "PAT001",
            patientName: "Test Patient",
            birthDate: "",
            studyInstanceUID: "1.2.3.4.5",
            studyDate: "",
            studyDescription: "",
            accessionNumber: "",
            studyModality: "CT",
            seriesInstanceUID: "1.2.3.4.5.1",
            seriesNumber: 1,
            seriesDescription: "",
            seriesModality: "CT",
            sopInstanceUID: "1.2.3.4.5.1.1",
            instanceNumber: 1,
            rows: 512,
            columns: 512,
            bitsAllocated: 16
        )

        try dbManager.insertFromTags(tags)
        try dbManager.insertFromTags(tags) // duplicate

        let patients = try dbManager.fetchPatients()
        #expect(patients.count == 1)

        let instances = try dbManager.fetchInstances(forSeries: 1)
        #expect(instances.count == 1)
    }
}

@Suite("FrameCache Tests")
struct FrameCacheTests {

    private static func makeTestFrame(width: Int = 10, height: Int = 10) -> FrameData {
        FrameData(
            pixels: [UInt16](repeating: 0, count: width * height),
            width: width, height: height, bitsStored: 12,
            rescaleSlope: 1.0, rescaleIntercept: 0.0,
            windowCenter: 40.0, windowWidth: 400.0,
            pixelSpacingX: 1.0, pixelSpacingY: 1.0)
    }

    @Test("Cache stores and retrieves frames")
    func cacheGetOrDecode() async throws {
        let cache = FrameCache(maxBytes: 1024 * 1024)
        let key = FrameCacheKey(seriesRowID: 1, instanceIndex: 0)

        let frame = try await cache.getOrDecode(key: key) {
            Self.makeTestFrame()
        }
        #expect(frame.width == 10)

        // Second call should hit cache — verify by returning a different frame
        let frame2 = try await cache.getOrDecode(key: key) {
            Self.makeTestFrame(width: 99, height: 99)
        }
        // Should still be the original cached frame, not the 99x99 one
        #expect(frame2.width == 10)
    }

    @Test("Cache evicts LRU entries when budget exceeded")
    func cacheLRUEviction() async throws {
        // Budget: just enough for 2 frames of 10x10 = 200 bytes each
        let cache = FrameCache(maxBytes: 400)

        let key1 = FrameCacheKey(seriesRowID: 1, instanceIndex: 0)
        let key2 = FrameCacheKey(seriesRowID: 1, instanceIndex: 1)
        let key3 = FrameCacheKey(seriesRowID: 1, instanceIndex: 2)

        _ = try await cache.getOrDecode(key: key1) { Self.makeTestFrame() }
        _ = try await cache.getOrDecode(key: key2) { Self.makeTestFrame() }

        // key1 should still be cached
        let has1 = await cache.contains(key1)
        #expect(has1)

        // Adding key3 should evict key1 (LRU)
        _ = try await cache.getOrDecode(key: key3) { Self.makeTestFrame() }
        let has1After = await cache.contains(key1)
        #expect(!has1After)

        let has3 = await cache.contains(key3)
        #expect(has3)
    }
}

@Suite("DicomUniforms Tests")
struct DicomUniformsTests {

    @Test("DicomUniforms has correct default values")
    func defaultValues() {
        let u = DicomUniforms()
        #expect(u.windowCenter == 40.0)
        #expect(u.windowWidth == 400.0)
        #expect(u.rescaleSlope == 1.0)
        #expect(u.rescaleIntercept == -1024.0)
        #expect(u.zoomScale == 1.0)
        #expect(u.panOffset.x == 0.0)
        #expect(u.panOffset.y == 0.0)
    }

    @Test("DicomUniforms memory layout is contiguous")
    func memoryLayout() {
        // Ensure the struct can be safely copied to a Metal buffer
        let size = MemoryLayout<DicomUniforms>.stride
        #expect(size > 0)
        // 4 floats + 1 float + 2 floats (SIMD2) = 7 floats minimum = 28 bytes
        #expect(size >= 28)
    }
}

@Suite("Annotation Tests")
struct AnnotationTests {

    @Test("Length calculation with pixel spacing")
    func lengthCalculation() {
        // Create a horizontal line from (0.1, 0.5) to (0.6, 0.5) in texture coords
        let annotation = LengthAnnotation(
            sliceIndex: 0,
            startPoint: TexturePoint(x: 0.1, y: 0.5),
            endPoint: TexturePoint(x: 0.6, y: 0.5))

        // Frame: 100x100 pixels, 1mm spacing
        let frame = FrameData(
            pixels: [UInt16](repeating: 0, count: 10000),
            width: 100, height: 100, bitsStored: 12,
            rescaleSlope: 1.0, rescaleIntercept: 0.0,
            windowCenter: 40.0, windowWidth: 400.0,
            pixelSpacingX: 1.0, pixelSpacingY: 1.0)

        let result = MeasurementCalculator.calculateLength(annotation, frameData: frame)

        // dx = 0.5 * 100 pixels * 1mm = 50mm
        #expect(result.unit == "mm")
        #expect(abs(result.value - 50.0) < 0.1)
    }

    @Test("Length calculation without pixel spacing")
    func lengthCalculationNoSpacing() {
        let annotation = LengthAnnotation(
            sliceIndex: 0,
            startPoint: TexturePoint(x: 0.0, y: 0.0),
            endPoint: TexturePoint(x: 1.0, y: 1.0))

        let frame = FrameData(
            pixels: [UInt16](repeating: 0, count: 10000),
            width: 100, height: 100, bitsStored: 12,
            rescaleSlope: 1.0, rescaleIntercept: 0.0,
            windowCenter: 40.0, windowWidth: 400.0,
            pixelSpacingX: nil, pixelSpacingY: nil)

        let result = MeasurementCalculator.calculateLength(annotation, frameData: frame)

        // Diagonal of 100x100 = sqrt(100^2 + 100^2) = 141.4
        #expect(result.unit == "px")
        #expect(abs(result.value - 141.4) < 1.0)
    }

    @Test("Angle calculation - right angle")
    func angleCalculationRightAngle() {
        // 90 degree angle
        let annotation = AngleAnnotation(
            sliceIndex: 0,
            pointA: TexturePoint(x: 0.0, y: 0.5),  // Left
            vertex: TexturePoint(x: 0.5, y: 0.5),  // Center
            pointC: TexturePoint(x: 0.5, y: 0.0))  // Up

        let result = MeasurementCalculator.calculateAngle(annotation)

        #expect(result.unit == "°")
        #expect(abs(result.value - 90.0) < 0.1)
    }

    @Test("Angle calculation - straight line")
    func angleCalculationStraightLine() {
        // 180 degree angle (straight line)
        let annotation = AngleAnnotation(
            sliceIndex: 0,
            pointA: TexturePoint(x: 0.0, y: 0.5),  // Left
            vertex: TexturePoint(x: 0.5, y: 0.5),  // Center
            pointC: TexturePoint(x: 1.0, y: 0.5))  // Right

        let result = MeasurementCalculator.calculateAngle(annotation)

        #expect(result.unit == "°")
        #expect(abs(result.value - 180.0) < 0.1)
    }

    @Test("TexturePoint distance calculation")
    func texturePointDistance() {
        let p1 = TexturePoint(x: 0.0, y: 0.0)
        let p2 = TexturePoint(x: 3.0, y: 4.0)

        let distance = p1.distance(to: p2)
        #expect(abs(distance - 5.0) < 0.001)  // 3-4-5 triangle
    }

    @Test("TexturePoint midpoint calculation")
    func texturePointMidpoint() {
        let p1 = TexturePoint(x: 0.0, y: 0.0)
        let p2 = TexturePoint(x: 1.0, y: 1.0)

        let mid = p1.midpoint(to: p2)
        #expect(abs(mid.x - 0.5) < 0.001)
        #expect(abs(mid.y - 0.5) < 0.001)
    }
}

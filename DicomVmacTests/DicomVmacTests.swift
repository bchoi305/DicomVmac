//
//  DicomVmacTests.swift
//  DicomVmacTests
//

import Foundation
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
            pixelSpacingX: 1.0, pixelSpacingY: 1.0,
            imagePositionZ: 0.0, sliceThickness: 1.0)
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
            pixelSpacingX: 1.0, pixelSpacingY: 1.0,
            imagePositionZ: 0.0, sliceThickness: 1.0)

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
            pixelSpacingX: nil, pixelSpacingY: nil,
            imagePositionZ: nil, sliceThickness: nil)

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

@Suite("MPR Tests")
struct MPRTests {

    @Test("MPRUniforms has correct default values")
    func mprUniformsDefaults() {
        let u = MPRUniforms()
        #expect(u.windowCenter == 40.0)
        #expect(u.windowWidth == 400.0)
        #expect(u.rescaleSlope == 1.0)
        #expect(u.rescaleIntercept == -1024.0)
        #expect(u.zoomScale == 1.0)
        #expect(u.slicePosition == 0.5)
        #expect(u.plane == 0)
        #expect(u.showCrosshair == 1)
    }

    @Test("MPRUniforms memory layout is contiguous")
    func mprUniformsLayout() {
        let size = MemoryLayout<MPRUniforms>.stride
        #expect(size > 0)
        // Verify struct can be safely copied to Metal buffer
        #expect(size >= 40) // Minimum expected size
    }

    @Test("VolumeData initialization")
    func volumeDataInit() {
        let data = VolumeData(
            seriesRowID: 1,
            width: 512,
            height: 512,
            depth: 100,
            pixelSpacingX: 0.5,
            pixelSpacingY: 0.5,
            sliceSpacing: 1.0,
            rescaleSlope: 1.0,
            rescaleIntercept: -1024.0,
            windowCenter: 40.0,
            windowWidth: 400.0,
            bitsStored: 12
        )

        #expect(data.width == 512)
        #expect(data.height == 512)
        #expect(data.depth == 100)
        #expect(data.sliceSpacing == 1.0)
    }

    @Test("MPRSlicePosition center initialization")
    func slicePositionCenter() {
        let pos = MPRSlicePosition.center
        #expect(pos.axial == 0.5)
        #expect(pos.coronal == 0.5)
        #expect(pos.sagittal == 0.5)
    }

    @Test("MPRPlane display names")
    func planeDisplayNames() {
        #expect(MPRPlane.axial.displayName == "Axial")
        #expect(MPRPlane.coronal.displayName == "Coronal")
        #expect(MPRPlane.sagittal.displayName == "Sagittal")
    }

    @Test("MPRPlane raw values")
    func planeRawValues() {
        #expect(MPRPlane.axial.rawValue == 0)
        #expect(MPRPlane.coronal.rawValue == 1)
        #expect(MPRPlane.sagittal.rawValue == 2)
    }

    @Test("VolumeLoadError descriptions")
    func volumeLoadErrorDescriptions() {
        let noInstances = VolumeLoadError.noInstances
        #expect(noInstances.errorDescription?.contains("No instances") == true)

        let inconsistent = VolumeLoadError.inconsistentDimensions
        #expect(inconsistent.errorDescription?.contains("inconsistent") == true)

        let insufficient = VolumeLoadError.insufficientSlices(count: 2)
        #expect(insufficient.errorDescription?.contains("3 slices") == true)
    }
}

@Suite("DICOMDIR Tests")
struct DicomdirTests {

    @Test("db_is_dicomdir returns 0 for non-existent path")
    func isdicomdirNonExistent() {
        let result = db_is_dicomdir("/nonexistent/path/DICOMDIR")
        #expect(result == 0)
    }

    @Test("db_is_dicomdir returns 0 for null path")
    func isdicomdirNull() {
        let result = db_is_dicomdir(nil)
        #expect(result == 0)
    }

    @Test("db_is_dicomdir returns 0 for regular file")
    func isdicomdirRegularFile() {
        // Use a known regular file (the app bundle executable)
        let bundlePath = Bundle.main.executablePath ?? "/usr/bin/true"
        let result = db_is_dicomdir(bundlePath)
        #expect(result == 0)
    }

    @Test("db_is_dicomdir returns 0 for empty directory")
    func isdicomdirEmptyDirectory() {
        // Create temp directory
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = db_is_dicomdir(tmpDir.path)
        #expect(result == 0)
    }

    @Test("Swift isDicomdir wrapper returns false for non-existent path")
    func swiftWrapperNonExistent() {
        let bridge = DicomBridgeWrapper()
        let result = bridge.isDicomdir(path: "/nonexistent/DICOMDIR")
        #expect(result == false)
    }

    @Test("Swift isDicomdir wrapper returns false for empty directory")
    func swiftWrapperEmptyDir() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bridge = DicomBridgeWrapper()
        let result = bridge.isDicomdir(path: tmpDir.path)
        #expect(result == false)
    }

    @Test("db_scan_dicomdir returns NOT_FOUND for non-existent path")
    func scanDicomdirNonExistent() {
        let status = db_scan_dicomdir("/nonexistent/DICOMDIR", { _, _, _ in }, nil, nil)
        #expect(status == DB_STATUS_NOT_FOUND)
    }

    @Test("db_scan_dicomdir returns ERROR for null path")
    func scanDicomdirNull() {
        let status = db_scan_dicomdir(nil, { _, _, _ in }, nil, nil)
        #expect(status == DB_STATUS_ERROR)
    }
}

@Suite("Hanging Protocol Tests")
struct HangingProtocolTests {

    @Test("Default layouts are defined")
    func layoutsExist() {
        #expect(HangingProtocol.layouts.count >= 4)
    }

    @Test("Layout properties are correct")
    func layoutProperties() {
        let layout1x1 = HangingProtocol.layouts[0]
        #expect(layout1x1.id == "1x1")
        #expect(layout1x1.rows == 1)
        #expect(layout1x1.cols == 1)
        #expect(layout1x1.cellCount == 1)

        let layout2x2 = HangingProtocol.layouts[3]
        #expect(layout2x2.id == "2x2")
        #expect(layout2x2.rows == 2)
        #expect(layout2x2.cols == 2)
        #expect(layout2x2.cellCount == 4)
    }

    @Test("Layout cell count calculation")
    func cellCount() {
        let layout = HangingProtocol(id: "2x3", name: "2×3", rows: 2, cols: 3, keyEquivalent: nil)
        #expect(layout.cellCount == 6)
    }

    @Test("Default layout is 1x1")
    func defaultLayout() {
        let defaultLayout = HangingProtocol.default
        #expect(defaultLayout.id == "1x1")
        #expect(defaultLayout.rows == 1)
        #expect(defaultLayout.cols == 1)
    }

    @Test("Layout lookup by ID")
    func layoutLookup() {
        let found = HangingProtocol.layout(withID: "2x2")
        #expect(found != nil)
        #expect(found?.rows == 2)
        #expect(found?.cols == 2)

        let notFound = HangingProtocol.layout(withID: "invalid")
        #expect(notFound == nil)
    }

    @Test("ViewerLinkOptions combinations")
    func linkOptions() {
        let options: ViewerLinkOptions = [.scroll, .windowLevel]
        #expect(options.contains(.scroll))
        #expect(options.contains(.windowLevel))
        #expect(!options.contains(.zoom))

        let all = ViewerLinkOptions.all
        #expect(all.contains(.scroll))
        #expect(all.contains(.windowLevel))
        #expect(all.contains(.zoom))

        let none = ViewerLinkOptions.none
        #expect(!none.contains(.scroll))
        #expect(!none.contains(.windowLevel))
        #expect(!none.contains(.zoom))
    }

    @Test("HangingProtocol equatable")
    func equatable() {
        let layout1 = HangingProtocol(id: "1x1", name: "1×1", rows: 1, cols: 1, keyEquivalent: "1")
        let layout2 = HangingProtocol(id: "1x1", name: "1×1", rows: 1, cols: 1, keyEquivalent: "1")
        let layout3 = HangingProtocol(id: "2x2", name: "2×2", rows: 2, cols: 2, keyEquivalent: "4")

        #expect(layout1 == layout2)
        #expect(layout1 != layout3)
    }
}

// MARK: - Volume Rendering Tests

@Suite("Volume Rendering Tests")
struct VolumeRenderingTests {

    @Test("VolumeRenderMode has all cases")
    func renderModeAllCases() {
        let modes = VolumeRenderMode.allCases
        #expect(modes.count == 5)
        #expect(modes.contains(.slice))
        #expect(modes.contains(.mip))
        #expect(modes.contains(.minip))
        #expect(modes.contains(.aip))
        #expect(modes.contains(.vr))
    }

    @Test("VolumeRenderMode display names")
    func renderModeDisplayNames() {
        #expect(VolumeRenderMode.slice.displayName == "Slice")
        #expect(VolumeRenderMode.mip.displayName == "MIP")
        #expect(VolumeRenderMode.minip.displayName == "MinIP")
        #expect(VolumeRenderMode.aip.displayName == "AIP")
        #expect(VolumeRenderMode.vr.displayName == "Volume Rendering")
    }

    @Test("VolumeRenderMode raw values")
    func renderModeRawValues() {
        #expect(VolumeRenderMode.slice.rawValue == 0)
        #expect(VolumeRenderMode.mip.rawValue == 1)
        #expect(VolumeRenderMode.minip.rawValue == 2)
        #expect(VolumeRenderMode.aip.rawValue == 3)
        #expect(VolumeRenderMode.vr.rawValue == 4)
    }

    @Test("VolumeRenderMode isProjectionMode")
    func renderModeIsProjection() {
        #expect(!VolumeRenderMode.slice.isProjectionMode)
        #expect(VolumeRenderMode.mip.isProjectionMode)
        #expect(VolumeRenderMode.minip.isProjectionMode)
        #expect(VolumeRenderMode.aip.isProjectionMode)
        #expect(VolumeRenderMode.vr.isProjectionMode)
    }

    @Test("VRPreset has all cases")
    func vrPresetAllCases() {
        let presets = VRPreset.allCases
        #expect(presets.count == 4)
        #expect(presets.contains(.bone))
        #expect(presets.contains(.softTissue))
        #expect(presets.contains(.lung))
        #expect(presets.contains(.angio))
    }

    @Test("VRPreset display names")
    func vrPresetDisplayNames() {
        #expect(VRPreset.bone.displayName == "Bone")
        #expect(VRPreset.softTissue.displayName == "Soft Tissue")
        #expect(VRPreset.lung.displayName == "Lung")
        #expect(VRPreset.angio.displayName == "Angio")
    }

    @Test("VRPreset raw values")
    func vrPresetRawValues() {
        #expect(VRPreset.bone.rawValue == "bone")
        #expect(VRPreset.softTissue.rawValue == "softTissue")
        #expect(VRPreset.lung.rawValue == "lung")
        #expect(VRPreset.angio.rawValue == "angio")
    }

    @Test("MPRPlane supports rotation")
    func planeSupportsRotation() {
        #expect(!MPRPlane.axial.supportsRotation)
        #expect(!MPRPlane.coronal.supportsRotation)
        #expect(!MPRPlane.sagittal.supportsRotation)
        #expect(MPRPlane.projection.supportsRotation)
    }

    @Test("MPRPlane projection display name")
    func projectionDisplayName() {
        #expect(MPRPlane.projection.displayName == "3D View")
        #expect(MPRPlane.projection.rawValue == 3)
    }
}

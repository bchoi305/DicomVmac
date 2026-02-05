//
//  AnnotationManager.swift
//  DicomVmac
//
//  Manages storage, retrieval, and selection of annotations.
//  Thread-safe via @MainActor for UI consistency.
//

import Foundation

/// Manages annotations for DICOM series.
/// Annotations are stored per-series and per-slice.
@MainActor
final class AnnotationManager: ObservableObject {

    /// Storage: [seriesRowID: [sliceIndex: [AnyAnnotation]]]
    private var storage: [Int64: [Int: [AnyAnnotation]]] = [:]

    /// Currently selected annotation ID (for deletion, editing).
    @Published private(set) var selectedAnnotationID: UUID?

    /// The series ID of the currently selected annotation.
    private var selectedSeriesID: Int64?

    // MARK: - CRUD Operations

    /// Add an annotation to a series at a specific slice.
    func addAnnotation(_ annotation: AnyAnnotation, seriesID: Int64) {
        let sliceIndex = annotation.sliceIndex
        if storage[seriesID] == nil {
            storage[seriesID] = [:]
        }
        if storage[seriesID]![sliceIndex] == nil {
            storage[seriesID]![sliceIndex] = []
        }
        storage[seriesID]![sliceIndex]!.append(annotation)
    }

    /// Remove an annotation by ID from a series.
    func removeAnnotation(id: UUID, seriesID: Int64) {
        guard var seriesStorage = storage[seriesID] else { return }

        for (sliceIndex, annotations) in seriesStorage {
            if let idx = annotations.firstIndex(where: { $0.id == id }) {
                seriesStorage[sliceIndex]?.remove(at: idx)
                storage[seriesID] = seriesStorage

                // Clear selection if removing selected annotation
                if selectedAnnotationID == id {
                    selectedAnnotationID = nil
                    selectedSeriesID = nil
                }
                return
            }
        }
    }

    /// Get all annotations for a specific series and slice.
    func annotations(forSeries seriesID: Int64, slice sliceIndex: Int) -> [AnyAnnotation] {
        storage[seriesID]?[sliceIndex] ?? []
    }

    /// Get all annotations for a series (all slices).
    func allAnnotations(forSeries seriesID: Int64) -> [AnyAnnotation] {
        guard let seriesStorage = storage[seriesID] else { return [] }
        return seriesStorage.values.flatMap { $0 }
    }

    /// Clear all annotations for a series.
    func clearAnnotations(forSeries seriesID: Int64) {
        storage[seriesID] = nil
        if selectedSeriesID == seriesID {
            selectedAnnotationID = nil
            selectedSeriesID = nil
        }
    }

    // MARK: - Selection

    /// Select an annotation by ID.
    func selectAnnotation(id: UUID?, seriesID: Int64?) {
        selectedAnnotationID = id
        selectedSeriesID = seriesID
    }

    /// Deselect any selected annotation.
    func clearSelection() {
        selectedAnnotationID = nil
        selectedSeriesID = nil
    }

    /// Delete the currently selected annotation.
    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationID, let seriesID = selectedSeriesID else { return }
        removeAnnotation(id: id, seriesID: seriesID)
    }

    // MARK: - Hit Testing

    /// Hit test to find an annotation near a texture coordinate.
    /// - Parameters:
    ///   - textureCoord: The texture coordinate (0-1 range).
    ///   - seriesID: The series to search in.
    ///   - sliceIndex: The slice to search in.
    ///   - tolerance: Hit tolerance in texture coordinates (default 0.02).
    /// - Returns: The annotation ID if hit, nil otherwise.
    func hitTest(
        textureCoord: TexturePoint,
        seriesID: Int64,
        sliceIndex: Int,
        tolerance: Float = 0.02
    ) -> UUID? {
        let sliceAnnotations = annotations(forSeries: seriesID, slice: sliceIndex)

        for annotation in sliceAnnotations.reversed() { // Check topmost first
            if hitTestAnnotation(annotation, at: textureCoord, tolerance: tolerance) {
                return annotation.id
            }
        }

        return nil
    }

    /// Test if a specific annotation is hit.
    private func hitTestAnnotation(
        _ annotation: AnyAnnotation,
        at point: TexturePoint,
        tolerance: Float
    ) -> Bool {
        switch annotation {
        case .length(let a):
            return hitTestLineSegment(
                point: point,
                start: a.startPoint,
                end: a.endPoint,
                tolerance: tolerance
            )

        case .angle(let a):
            // Test both arms of the angle
            return hitTestLineSegment(point: point, start: a.pointA, end: a.vertex, tolerance: tolerance)
                || hitTestLineSegment(point: point, start: a.vertex, end: a.pointC, tolerance: tolerance)

        case .roi(let a):
            // Test polygon edges
            guard a.points.count >= 2 else { return false }
            for i in 0..<(a.points.count - 1) {
                if hitTestLineSegment(
                    point: point,
                    start: a.points[i],
                    end: a.points[i + 1],
                    tolerance: tolerance
                ) {
                    return true
                }
            }
            // Test closing edge if closed
            if a.isClosed && a.points.count >= 3 {
                if hitTestLineSegment(
                    point: point,
                    start: a.points.last!,
                    end: a.points.first!,
                    tolerance: tolerance
                ) {
                    return true
                }
            }
            return false

        case .ellipse(let a):
            // Test if point is near the ellipse edge
            let dx = (point.x - a.center.x) / a.radiusX
            let dy = (point.y - a.center.y) / a.radiusY
            let dist = sqrt(dx * dx + dy * dy)
            // Point is on edge if normalized distance is close to 1
            let edgeDist = abs(dist - 1.0) * max(a.radiusX, a.radiusY)
            return edgeDist < tolerance
        }
    }

    /// Test if a point is near a line segment.
    private func hitTestLineSegment(
        point: TexturePoint,
        start: TexturePoint,
        end: TexturePoint,
        tolerance: Float
    ) -> Bool {
        let lineLen = start.distance(to: end)
        if lineLen < 0.0001 {
            // Degenerate line, test as point
            return point.distance(to: start) < tolerance
        }

        // Calculate perpendicular distance from point to line
        let dx = end.x - start.x
        let dy = end.y - start.y
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (lineLen * lineLen)))
        let projX = start.x + t * dx
        let projY = start.y + t * dy
        let dist = sqrt((point.x - projX) * (point.x - projX) + (point.y - projY) * (point.y - projY))

        return dist < tolerance
    }

    // MARK: - Annotation Update

    /// Update an ROI annotation (for adding points while drawing).
    func updateROI(id: UUID, seriesID: Int64, points: [TexturePoint], isClosed: Bool) {
        guard var seriesStorage = storage[seriesID] else { return }

        for (sliceIndex, annotations) in seriesStorage {
            if let idx = annotations.firstIndex(where: { $0.id == id }) {
                if case .roi(var roi) = annotations[idx] {
                    roi.points = points
                    roi.isClosed = isClosed
                    seriesStorage[sliceIndex]![idx] = .roi(roi)
                    storage[seriesID] = seriesStorage
                }
                return
            }
        }
    }
}

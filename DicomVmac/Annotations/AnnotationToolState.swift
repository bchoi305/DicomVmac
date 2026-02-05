//
//  AnnotationToolState.swift
//  DicomVmac
//
//  State machine for annotation tool input handling.
//  Tracks in-progress annotations and manages point collection.
//

import Foundation

/// Available annotation tools.
enum AnnotationTool: String, CaseIterable {
    case none = "View"
    case length = "Length"
    case angle = "Angle"
    case polygonROI = "Polygon ROI"
    case ellipseROI = "Ellipse ROI"
}

/// State machine for handling annotation input.
@MainActor
final class AnnotationToolState {

    /// Current active tool.
    private(set) var currentTool: AnnotationTool = .none

    /// Slice index where annotation is being created.
    private var currentSliceIndex: Int = 0

    /// Accumulated points for in-progress annotation.
    private var points: [TexturePoint] = []

    /// In-progress ellipse center (for drag creation).
    private var ellipseCenter: TexturePoint?

    /// Callback when annotation is complete.
    var onAnnotationComplete: ((AnyAnnotation) -> Void)?

    /// Callback for preview updates (in-progress annotation).
    var onPreviewUpdate: (([TexturePoint], AnnotationTool) -> Void)?

    /// Callback when tool is cancelled.
    var onCancel: (() -> Void)?

    // MARK: - Tool Selection

    func setTool(_ tool: AnnotationTool) {
        if tool != currentTool {
            cancel()
        }
        currentTool = tool
    }

    /// Set the current slice index for new annotations.
    func setSliceIndex(_ index: Int) {
        if index != currentSliceIndex {
            // Cancel in-progress annotation if changing slices
            cancel()
        }
        currentSliceIndex = index
    }

    // MARK: - Input Handling

    /// Handle a click at the given texture coordinate.
    func handleClick(at point: TexturePoint) {
        guard currentTool != .none else { return }

        switch currentTool {
        case .none:
            break

        case .length:
            handleLengthClick(at: point)

        case .angle:
            handleAngleClick(at: point)

        case .polygonROI:
            handlePolygonClick(at: point)

        case .ellipseROI:
            // Ellipse is created via drag, not click
            break
        }
    }

    /// Handle drag start for ellipse creation.
    func handleDragStart(at point: TexturePoint) {
        guard currentTool == .ellipseROI else { return }
        ellipseCenter = point
        onPreviewUpdate?([point], .ellipseROI)
    }

    /// Handle drag continuation for ellipse sizing.
    func handleDrag(to point: TexturePoint) {
        guard currentTool == .ellipseROI, let center = ellipseCenter else { return }
        onPreviewUpdate?([center, point], .ellipseROI)
    }

    /// Handle drag end to complete ellipse.
    func handleDragEnd(at point: TexturePoint) {
        guard currentTool == .ellipseROI, let center = ellipseCenter else { return }

        let radiusX = abs(point.x - center.x)
        let radiusY = abs(point.y - center.y)

        // Require minimum size
        guard radiusX > 0.01 || radiusY > 0.01 else {
            cancel()
            return
        }

        let annotation = EllipseROIAnnotation(
            sliceIndex: currentSliceIndex,
            center: center,
            radiusX: radiusX,
            radiusY: radiusY)
        onAnnotationComplete?(.ellipse(annotation))

        ellipseCenter = nil
        onPreviewUpdate?([], .ellipseROI)
    }

    /// Handle mouse move for preview (e.g., rubber-banding).
    func handleMove(to point: TexturePoint) {
        guard currentTool != .none && !points.isEmpty else { return }

        var previewPoints = points
        previewPoints.append(point)
        onPreviewUpdate?(previewPoints, currentTool)
    }

    /// Cancel the current in-progress annotation.
    func cancel() {
        points.removeAll()
        ellipseCenter = nil
        onPreviewUpdate?([], currentTool)
        onCancel?()
    }

    /// Returns true if an annotation is currently in progress.
    var isDrawing: Bool {
        !points.isEmpty || ellipseCenter != nil
    }

    // MARK: - Length Tool

    private func handleLengthClick(at point: TexturePoint) {
        points.append(point)

        if points.count == 2 {
            let annotation = LengthAnnotation(
                sliceIndex: currentSliceIndex,
                startPoint: points[0],
                endPoint: points[1])
            onAnnotationComplete?(.length(annotation))
            points.removeAll()
            onPreviewUpdate?([], .length)
        } else {
            onPreviewUpdate?(points, .length)
        }
    }

    // MARK: - Angle Tool

    private func handleAngleClick(at point: TexturePoint) {
        points.append(point)

        if points.count == 3 {
            let annotation = AngleAnnotation(
                sliceIndex: currentSliceIndex,
                pointA: points[0],
                vertex: points[1],
                pointC: points[2])
            onAnnotationComplete?(.angle(annotation))
            points.removeAll()
            onPreviewUpdate?([], .angle)
        } else {
            onPreviewUpdate?(points, .angle)
        }
    }

    // MARK: - Polygon ROI Tool

    private func handlePolygonClick(at point: TexturePoint) {
        // Check if clicking near the first point to close
        if points.count >= 3 {
            let first = points[0]
            if point.distance(to: first) < 0.03 {
                // Close the polygon
                let annotation = ROIAnnotation(
                    sliceIndex: currentSliceIndex,
                    points: points,
                    isClosed: true)
                onAnnotationComplete?(.roi(annotation))
                points.removeAll()
                onPreviewUpdate?([], .polygonROI)
                return
            }
        }

        points.append(point)
        onPreviewUpdate?(points, .polygonROI)
    }
}

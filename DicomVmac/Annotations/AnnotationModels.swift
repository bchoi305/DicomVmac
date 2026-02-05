//
//  AnnotationModels.swift
//  DicomVmac
//
//  Data models for DICOM image annotations (measurements, ROIs).
//  Coordinates are stored in texture space (0-1 range).
//

import Foundation

/// A point in texture coordinate space (0-1 range).
/// (0,0) is top-left, (1,1) is bottom-right.
struct TexturePoint: Equatable, Sendable, Codable {
    let x: Float
    let y: Float

    static let zero = TexturePoint(x: 0, y: 0)

    /// Distance to another point in texture space.
    func distance(to other: TexturePoint) -> Float {
        let dx = other.x - x
        let dy = other.y - y
        return sqrt(dx * dx + dy * dy)
    }

    /// Midpoint between this point and another.
    func midpoint(to other: TexturePoint) -> TexturePoint {
        TexturePoint(x: (x + other.x) / 2, y: (y + other.y) / 2)
    }
}

/// Length measurement annotation (two-point ruler).
struct LengthAnnotation: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let sliceIndex: Int
    let startPoint: TexturePoint
    let endPoint: TexturePoint

    init(id: UUID = UUID(), sliceIndex: Int, startPoint: TexturePoint, endPoint: TexturePoint) {
        self.id = id
        self.sliceIndex = sliceIndex
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    /// Center point for label placement.
    var center: TexturePoint {
        startPoint.midpoint(to: endPoint)
    }
}

/// Angle measurement annotation (three-point protractor).
/// The angle is measured at the vertex (middle point).
struct AngleAnnotation: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let sliceIndex: Int
    let pointA: TexturePoint   // First arm endpoint
    let vertex: TexturePoint   // Angle vertex (middle point)
    let pointC: TexturePoint   // Second arm endpoint

    init(id: UUID = UUID(), sliceIndex: Int, pointA: TexturePoint, vertex: TexturePoint, pointC: TexturePoint) {
        self.id = id
        self.sliceIndex = sliceIndex
        self.pointA = pointA
        self.vertex = vertex
        self.pointC = pointC
    }

    /// Center point for label placement (at the vertex).
    var center: TexturePoint {
        vertex
    }
}

/// Polygon ROI annotation for mean/std pixel statistics.
struct ROIAnnotation: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let sliceIndex: Int
    var points: [TexturePoint]
    var isClosed: Bool

    init(id: UUID = UUID(), sliceIndex: Int, points: [TexturePoint] = [], isClosed: Bool = false) {
        self.id = id
        self.sliceIndex = sliceIndex
        self.points = points
        self.isClosed = isClosed
    }

    /// Centroid of the polygon for label placement.
    var center: TexturePoint {
        guard !points.isEmpty else { return .zero }
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let count = Float(points.count)
        return TexturePoint(x: sumX / count, y: sumY / count)
    }
}

/// Ellipse ROI annotation for mean/std pixel statistics.
struct EllipseROIAnnotation: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let sliceIndex: Int
    let center: TexturePoint
    let radiusX: Float  // Horizontal radius in texture coords
    let radiusY: Float  // Vertical radius in texture coords

    init(id: UUID = UUID(), sliceIndex: Int, center: TexturePoint, radiusX: Float, radiusY: Float) {
        self.id = id
        self.sliceIndex = sliceIndex
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
    }
}

/// Type-erased wrapper for any annotation type.
enum AnyAnnotation: Identifiable, Equatable, Sendable, Codable {
    case length(LengthAnnotation)
    case angle(AngleAnnotation)
    case roi(ROIAnnotation)
    case ellipse(EllipseROIAnnotation)

    var id: UUID {
        switch self {
        case .length(let a): return a.id
        case .angle(let a): return a.id
        case .roi(let a): return a.id
        case .ellipse(let a): return a.id
        }
    }

    var sliceIndex: Int {
        switch self {
        case .length(let a): return a.sliceIndex
        case .angle(let a): return a.sliceIndex
        case .roi(let a): return a.sliceIndex
        case .ellipse(let a): return a.sliceIndex
        }
    }

    /// Center point for label placement.
    var center: TexturePoint {
        switch self {
        case .length(let a): return a.center
        case .angle(let a): return a.center
        case .roi(let a): return a.center
        case .ellipse(let a): return a.center
        }
    }

    /// All points in the annotation (for hit testing and rendering).
    var allPoints: [TexturePoint] {
        switch self {
        case .length(let a):
            return [a.startPoint, a.endPoint]
        case .angle(let a):
            return [a.pointA, a.vertex, a.pointC]
        case .roi(let a):
            return a.points
        case .ellipse(let a):
            // Return center and 4 edge points for hit testing
            return [
                a.center,
                TexturePoint(x: a.center.x + a.radiusX, y: a.center.y),
                TexturePoint(x: a.center.x - a.radiusX, y: a.center.y),
                TexturePoint(x: a.center.x, y: a.center.y + a.radiusY),
                TexturePoint(x: a.center.x, y: a.center.y - a.radiusY)
            ]
        }
    }
}

/// Result of a measurement calculation.
struct MeasurementResult: Sendable {
    let value: Double
    let unit: String
    let formattedString: String
}

/// Statistics for an ROI region.
struct ROIStatistics: Sendable {
    let mean: Double
    let standardDeviation: Double
    let min: Double
    let max: Double
    let pixelCount: Int

    var formattedString: String {
        String(format: "Mean: %.1f HU\nSD: %.1f HU", mean, standardDeviation)
    }
}

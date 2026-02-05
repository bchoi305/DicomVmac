//
//  MeasurementCalculator.swift
//  DicomVmac
//
//  Calculates physical measurements from annotations using DICOM pixel spacing.
//

import Foundation

/// Calculator for physical measurements from annotations.
struct MeasurementCalculator {

    // MARK: - Length Calculation

    /// Calculate the physical length of a line annotation.
    /// - Parameters:
    ///   - annotation: The length annotation.
    ///   - frameData: Frame data containing pixel spacing.
    /// - Returns: The measurement result with length in mm.
    static func calculateLength(
        _ annotation: LengthAnnotation,
        frameData: FrameData
    ) -> MeasurementResult {
        let dx = annotation.endPoint.x - annotation.startPoint.x
        let dy = annotation.endPoint.y - annotation.startPoint.y

        // Convert from texture coords (0-1) to pixel coords
        let pixelDx = dx * Float(frameData.width)
        let pixelDy = dy * Float(frameData.height)

        // Apply pixel spacing if available
        if let spacingX = frameData.pixelSpacingX,
           let spacingY = frameData.pixelSpacingY {
            let mmDx = Double(pixelDx) * spacingX
            let mmDy = Double(pixelDy) * spacingY
            let lengthMm = sqrt(mmDx * mmDx + mmDy * mmDy)
            return MeasurementResult(
                value: lengthMm,
                unit: "mm",
                formattedString: String(format: "%.1f mm", lengthMm))
        } else {
            // Fallback to pixel distance
            let lengthPx = sqrt(Double(pixelDx * pixelDx + pixelDy * pixelDy))
            return MeasurementResult(
                value: lengthPx,
                unit: "px",
                formattedString: String(format: "%.1f px", lengthPx))
        }
    }

    // MARK: - Angle Calculation

    /// Calculate the angle of an angle annotation.
    /// - Parameter annotation: The angle annotation.
    /// - Returns: The measurement result with angle in degrees.
    static func calculateAngle(_ annotation: AngleAnnotation) -> MeasurementResult {
        // Vector from vertex to point A
        let ax = annotation.pointA.x - annotation.vertex.x
        let ay = annotation.pointA.y - annotation.vertex.y

        // Vector from vertex to point C
        let cx = annotation.pointC.x - annotation.vertex.x
        let cy = annotation.pointC.y - annotation.vertex.y

        // Calculate angle using dot product
        let dot = ax * cx + ay * cy
        let magA = sqrt(ax * ax + ay * ay)
        let magC = sqrt(cx * cx + cy * cy)

        guard magA > 0 && magC > 0 else {
            return MeasurementResult(value: 0, unit: "°", formattedString: "0.0°")
        }

        let cosAngle = dot / (magA * magC)
        let clampedCos = max(-1, min(1, cosAngle)) // Clamp to [-1, 1]
        let angleRad = acos(clampedCos)
        let angleDeg = Double(angleRad) * 180.0 / .pi

        return MeasurementResult(
            value: angleDeg,
            unit: "°",
            formattedString: String(format: "%.1f°", angleDeg))
    }

    // MARK: - ROI Statistics

    /// Calculate statistics for a polygon ROI.
    /// - Parameters:
    ///   - annotation: The ROI annotation.
    ///   - frameData: Frame data containing pixels.
    /// - Returns: ROI statistics (mean, std, min, max in HU).
    static func calculateROIStatistics(
        _ annotation: ROIAnnotation,
        frameData: FrameData
    ) -> ROIStatistics? {
        guard annotation.isClosed && annotation.points.count >= 3 else { return nil }

        let pixelValues = getPixelsInPolygon(
            points: annotation.points,
            frameData: frameData)

        return calculateStatistics(pixelValues, frameData: frameData)
    }

    /// Calculate statistics for an ellipse ROI.
    /// - Parameters:
    ///   - annotation: The ellipse annotation.
    ///   - frameData: Frame data containing pixels.
    /// - Returns: ROI statistics (mean, std, min, max in HU).
    static func calculateEllipseStatistics(
        _ annotation: EllipseROIAnnotation,
        frameData: FrameData
    ) -> ROIStatistics? {
        let pixelValues = getPixelsInEllipse(
            center: annotation.center,
            radiusX: annotation.radiusX,
            radiusY: annotation.radiusY,
            frameData: frameData)

        return calculateStatistics(pixelValues, frameData: frameData)
    }

    // MARK: - Pixel Collection

    /// Get all pixel values inside a polygon using scanline fill algorithm.
    private static func getPixelsInPolygon(
        points: [TexturePoint],
        frameData: FrameData
    ) -> [UInt16] {
        guard points.count >= 3 else { return [] }

        let width = frameData.width
        let height = frameData.height

        // Convert texture coords to pixel coords
        let pixelPoints = points.map { point -> (x: Int, y: Int) in
            (x: Int(point.x * Float(width)), y: Int(point.y * Float(height)))
        }

        // Find bounding box
        let minY = max(0, pixelPoints.map { $0.y }.min()!)
        let maxY = min(height - 1, pixelPoints.map { $0.y }.max()!)

        var result: [UInt16] = []

        // Scanline fill
        for y in minY...maxY {
            var intersections: [Int] = []

            for i in 0..<pixelPoints.count {
                let j = (i + 1) % pixelPoints.count
                let p1 = pixelPoints[i]
                let p2 = pixelPoints[j]

                // Check if scanline intersects this edge
                if (p1.y <= y && p2.y > y) || (p2.y <= y && p1.y > y) {
                    let dy = p2.y - p1.y
                    if dy != 0 {
                        let x = p1.x + (y - p1.y) * (p2.x - p1.x) / dy
                        intersections.append(x)
                    }
                }
            }

            intersections.sort()

            // Fill between pairs of intersections
            for i in stride(from: 0, to: intersections.count - 1, by: 2) {
                let x1 = max(0, intersections[i])
                let x2 = min(width - 1, intersections[i + 1])
                for x in x1...x2 {
                    let idx = y * width + x
                    if idx >= 0 && idx < frameData.pixels.count {
                        result.append(frameData.pixels[idx])
                    }
                }
            }
        }

        return result
    }

    /// Get all pixel values inside an ellipse.
    private static func getPixelsInEllipse(
        center: TexturePoint,
        radiusX: Float,
        radiusY: Float,
        frameData: FrameData
    ) -> [UInt16] {
        let width = frameData.width
        let height = frameData.height

        // Convert to pixel coords
        let cx = Int(center.x * Float(width))
        let cy = Int(center.y * Float(height))
        let rx = Int(radiusX * Float(width))
        let ry = Int(radiusY * Float(height))

        var result: [UInt16] = []

        // Iterate over bounding box
        let minX = max(0, cx - rx)
        let maxX = min(width - 1, cx + rx)
        let minY = max(0, cy - ry)
        let maxY = min(height - 1, cy + ry)

        for y in minY...maxY {
            for x in minX...maxX {
                // Check if point is inside ellipse
                let dx = Float(x - cx)
                let dy = Float(y - cy)
                let rxf = Float(rx)
                let ryf = Float(ry)

                if rxf > 0 && ryf > 0 {
                    let normalized = (dx * dx) / (rxf * rxf) + (dy * dy) / (ryf * ryf)
                    if normalized <= 1.0 {
                        let idx = y * width + x
                        if idx >= 0 && idx < frameData.pixels.count {
                            result.append(frameData.pixels[idx])
                        }
                    }
                }
            }
        }

        return result
    }

    /// Calculate statistics from pixel values.
    private static func calculateStatistics(
        _ pixelValues: [UInt16],
        frameData: FrameData
    ) -> ROIStatistics? {
        guard !pixelValues.isEmpty else { return nil }

        // Convert to HU
        let huValues = pixelValues.map { value -> Double in
            Double(value) * frameData.rescaleSlope + frameData.rescaleIntercept
        }

        let count = Double(huValues.count)
        let sum = huValues.reduce(0, +)
        let mean = sum / count

        let sumSquaredDiff = huValues.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let variance = sumSquaredDiff / count
        let std = sqrt(variance)

        let minVal = huValues.min() ?? 0
        let maxVal = huValues.max() ?? 0

        return ROIStatistics(
            mean: mean,
            standardDeviation: std,
            min: minVal,
            max: maxVal,
            pixelCount: pixelValues.count)
    }

    // MARK: - Formatted Measurement Strings

    /// Get a formatted measurement string for any annotation.
    /// - Parameters:
    ///   - annotation: The annotation to measure.
    ///   - frameData: Optional frame data for physical measurements.
    /// - Returns: A formatted string for display.
    static func getMeasurementString(
        for annotation: AnyAnnotation,
        frameData: FrameData?
    ) -> String? {
        switch annotation {
        case .length(let a):
            guard let frame = frameData else { return nil }
            return calculateLength(a, frameData: frame).formattedString

        case .angle(let a):
            return calculateAngle(a).formattedString

        case .roi(let a):
            guard let frame = frameData,
                  let stats = calculateROIStatistics(a, frameData: frame) else { return nil }
            return stats.formattedString

        case .ellipse(let a):
            guard let frame = frameData,
                  let stats = calculateEllipseStatistics(a, frameData: frame) else { return nil }
            return stats.formattedString
        }
    }
}

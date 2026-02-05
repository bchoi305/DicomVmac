//
//  AnnotationRenderer.swift
//  DicomVmac
//
//  Metal renderer for annotation overlays (lines, shapes).
//  Renders on top of the DICOM image with proper zoom/pan transform.
//

import Foundation
import Metal
import simd

/// Swift mirror of the Metal AnnotationUniforms struct.
struct AnnotationUniforms {
    var zoomScale: Float = 1.0
    var panOffset: SIMD2<Float> = .zero
    var color: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 0.0, 1.0)  // Yellow default
}

/// Annotation vertex data (texture coordinate).
struct AnnotationVertex {
    var position: SIMD2<Float>
}

final class AnnotationRenderer {

    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private var uniformBuffer: MTLBuffer
    private var uniforms = AnnotationUniforms()

    // Annotation colors
    static let defaultColor = SIMD4<Float>(1.0, 1.0, 0.0, 1.0)      // Yellow
    static let selectedColor = SIMD4<Float>(0.0, 1.0, 1.0, 1.0)     // Cyan
    static let lengthColor = SIMD4<Float>(0.0, 1.0, 0.0, 1.0)       // Green
    static let angleColor = SIMD4<Float>(1.0, 0.5, 0.0, 1.0)        // Orange
    static let roiColor = SIMD4<Float>(1.0, 0.0, 1.0, 1.0)          // Magenta

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        self.device = device

        // Create pipeline descriptor with blending for transparent overlays
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "annotationVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "annotationFragmentShader")

        // Vertex descriptor for position attribute
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 1
        vertexDescriptor.layouts[1].stride = MemoryLayout<AnnotationVertex>.stride
        pipelineDescriptor.vertexDescriptor = vertexDescriptor

        // Configure blending for overlays
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        guard let buffer = device.makeBuffer(
            length: MemoryLayout<AnnotationUniforms>.stride,
            options: .storageModeShared
        ) else {
            throw AnnotationRendererError.bufferCreationFailed
        }
        self.uniformBuffer = buffer
    }

    /// Render annotations for the current slice.
    /// - Parameters:
    ///   - annotations: List of annotations to render.
    ///   - selectedID: ID of the selected annotation (for highlighting).
    ///   - zoomScale: Current zoom scale.
    ///   - panOffset: Current pan offset.
    ///   - encoder: The render command encoder to use.
    func render(
        annotations: [AnyAnnotation],
        selectedID: UUID?,
        zoomScale: Float,
        panOffset: SIMD2<Float>,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !annotations.isEmpty else { return }

        encoder.setRenderPipelineState(pipelineState)

        // Update zoom/pan in uniforms
        uniforms.zoomScale = zoomScale
        uniforms.panOffset = panOffset

        for annotation in annotations {
            let isSelected = annotation.id == selectedID
            renderAnnotation(annotation, isSelected: isSelected, encoder: encoder)
        }
    }

    private func renderAnnotation(
        _ annotation: AnyAnnotation,
        isSelected: Bool,
        encoder: MTLRenderCommandEncoder
    ) {
        switch annotation {
        case .length(let a):
            renderLength(a, isSelected: isSelected, encoder: encoder)
        case .angle(let a):
            renderAngle(a, isSelected: isSelected, encoder: encoder)
        case .roi(let a):
            renderROI(a, isSelected: isSelected, encoder: encoder)
        case .ellipse(let a):
            renderEllipse(a, isSelected: isSelected, encoder: encoder)
        }
    }

    // MARK: - Length Annotation

    private func renderLength(
        _ annotation: LengthAnnotation,
        isSelected: Bool,
        encoder: MTLRenderCommandEncoder
    ) {
        let vertices = [
            AnnotationVertex(position: SIMD2(annotation.startPoint.x, annotation.startPoint.y)),
            AnnotationVertex(position: SIMD2(annotation.endPoint.x, annotation.endPoint.y))
        ]

        uniforms.color = isSelected ? Self.selectedColor : Self.lengthColor
        drawLines(vertices: vertices, encoder: encoder)

        // Draw endpoint markers
        drawPointMarker(at: annotation.startPoint, isSelected: isSelected, encoder: encoder)
        drawPointMarker(at: annotation.endPoint, isSelected: isSelected, encoder: encoder)
    }

    // MARK: - Angle Annotation

    private func renderAngle(
        _ annotation: AngleAnnotation,
        isSelected: Bool,
        encoder: MTLRenderCommandEncoder
    ) {
        // Draw the two arms of the angle
        let vertices = [
            AnnotationVertex(position: SIMD2(annotation.pointA.x, annotation.pointA.y)),
            AnnotationVertex(position: SIMD2(annotation.vertex.x, annotation.vertex.y)),
            AnnotationVertex(position: SIMD2(annotation.vertex.x, annotation.vertex.y)),
            AnnotationVertex(position: SIMD2(annotation.pointC.x, annotation.pointC.y))
        ]

        uniforms.color = isSelected ? Self.selectedColor : Self.angleColor
        drawLines(vertices: vertices, encoder: encoder)

        // Draw point markers
        drawPointMarker(at: annotation.pointA, isSelected: isSelected, encoder: encoder)
        drawPointMarker(at: annotation.vertex, isSelected: isSelected, encoder: encoder)
        drawPointMarker(at: annotation.pointC, isSelected: isSelected, encoder: encoder)
    }

    // MARK: - ROI Annotation

    private func renderROI(
        _ annotation: ROIAnnotation,
        isSelected: Bool,
        encoder: MTLRenderCommandEncoder
    ) {
        guard annotation.points.count >= 2 else { return }

        var vertices: [AnnotationVertex] = []

        // Create line segments between consecutive points
        for i in 0..<(annotation.points.count - 1) {
            vertices.append(AnnotationVertex(position: SIMD2(annotation.points[i].x, annotation.points[i].y)))
            vertices.append(AnnotationVertex(position: SIMD2(annotation.points[i + 1].x, annotation.points[i + 1].y)))
        }

        // Close the polygon if closed
        if annotation.isClosed && annotation.points.count >= 3 {
            vertices.append(AnnotationVertex(position: SIMD2(annotation.points.last!.x, annotation.points.last!.y)))
            vertices.append(AnnotationVertex(position: SIMD2(annotation.points.first!.x, annotation.points.first!.y)))
        }

        uniforms.color = isSelected ? Self.selectedColor : Self.roiColor
        drawLines(vertices: vertices, encoder: encoder)
    }

    // MARK: - Ellipse Annotation

    private func renderEllipse(
        _ annotation: EllipseROIAnnotation,
        isSelected: Bool,
        encoder: MTLRenderCommandEncoder
    ) {
        // Generate ellipse vertices (32 segments)
        let segments = 32
        var vertices: [AnnotationVertex] = []

        for i in 0..<segments {
            let angle1 = Float(i) / Float(segments) * 2.0 * Float.pi
            let angle2 = Float(i + 1) / Float(segments) * 2.0 * Float.pi

            let x1 = annotation.center.x + cos(angle1) * annotation.radiusX
            let y1 = annotation.center.y + sin(angle1) * annotation.radiusY
            let x2 = annotation.center.x + cos(angle2) * annotation.radiusX
            let y2 = annotation.center.y + sin(angle2) * annotation.radiusY

            vertices.append(AnnotationVertex(position: SIMD2(x1, y1)))
            vertices.append(AnnotationVertex(position: SIMD2(x2, y2)))
        }

        uniforms.color = isSelected ? Self.selectedColor : Self.roiColor
        drawLines(vertices: vertices, encoder: encoder)
    }

    // MARK: - Drawing Helpers

    private func drawLines(vertices: [AnnotationVertex], encoder: MTLRenderCommandEncoder) {
        guard !vertices.isEmpty else { return }

        // Update uniform buffer
        uniformBuffer.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<AnnotationUniforms>.stride)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)

        // Create vertex buffer
        let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<AnnotationVertex>.stride,
            options: .storageModeShared)

        guard let vb = vertexBuffer else { return }
        encoder.setVertexBuffer(vb, offset: 0, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
    }

    private func drawPointMarker(
        at point: TexturePoint,
        isSelected: Bool,
        encoder: MTLRenderCommandEncoder
    ) {
        // Draw a small cross at the point
        let size: Float = 0.008  // Size in texture coordinates

        let vertices = [
            // Horizontal line
            AnnotationVertex(position: SIMD2(point.x - size, point.y)),
            AnnotationVertex(position: SIMD2(point.x + size, point.y)),
            // Vertical line
            AnnotationVertex(position: SIMD2(point.x, point.y - size)),
            AnnotationVertex(position: SIMD2(point.x, point.y + size))
        ]

        uniforms.color = isSelected ? Self.selectedColor : Self.defaultColor
        drawLines(vertices: vertices, encoder: encoder)
    }

    enum AnnotationRendererError: Error {
        case bufferCreationFailed
    }
}

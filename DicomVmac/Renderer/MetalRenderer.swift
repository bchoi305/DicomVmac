//
//  MetalRenderer.swift
//  DicomVmac
//
//  Metal renderer for DICOM image display.
//  Uses a uniform buffer for dynamic Window/Level, zoom, and pan.
//

import Foundation
import Metal
import MetalKit

/// Swift mirror of the Metal DicomUniforms struct.
struct DicomUniforms {
    var windowCenter: Float = 40.0
    var windowWidth: Float = 400.0
    var rescaleSlope: Float = 1.0
    var rescaleIntercept: Float = -1024.0
    var zoomScale: Float = 1.0
    var panOffset: SIMD2<Float> = .zero
}

final class MetalRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var uniformBuffer: MTLBuffer
    private var uniforms = DicomUniforms()
    private var currentTexture: MTLTexture?

    /// Annotation renderer for overlay graphics.
    private(set) var annotationRenderer: AnnotationRenderer?

    /// Current annotations to render (set by ViewerViewController).
    var annotations: [AnyAnnotation] = []

    /// Currently selected annotation ID (for highlighting).
    var selectedAnnotationID: UUID?

    init(metalView: MTKView) throws {
        guard let device = metalView.device,
              let commandQueue = device.makeCommandQueue() else {
            throw RendererError.initializationFailed("Cannot create Metal device or command queue")
        }

        self.device = device
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary() else {
            throw RendererError.initializationFailed("Cannot load Metal shader library")
        }

        let pixelFormat = metalView.colorPixelFormat
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat

        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        guard let buffer = device.makeBuffer(
            length: MemoryLayout<DicomUniforms>.stride,
            options: .storageModeShared
        ) else {
            throw RendererError.initializationFailed("Cannot create uniform buffer")
        }
        self.uniformBuffer = buffer

        super.init()

        // Initialize annotation renderer
        do {
            self.annotationRenderer = try AnnotationRenderer(
                device: device,
                library: library,
                pixelFormat: pixelFormat)
        } catch {
            NSLog("[MetalRenderer] Failed to create annotation renderer: %@", error.localizedDescription)
        }

        syncUniforms()
        createTestTexture()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resize if needed
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                  descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)

        // Bind uniform buffer to both vertex and fragment shaders
        renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)

        if let texture = currentTexture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }

        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Render annotations on top of the DICOM image
        annotationRenderer?.render(
            annotations: annotations,
            selectedID: selectedAnnotationID,
            zoomScale: uniforms.zoomScale,
            panOffset: uniforms.panOffset,
            encoder: renderEncoder)

        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Uniform Updates

    private func syncUniforms() {
        uniformBuffer.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<DicomUniforms>.stride)
    }

    func setWindowLevel(center: Float, width: Float) {
        uniforms.windowCenter = center
        uniforms.windowWidth = max(width, 1.0)
        syncUniforms()
    }

    func setRescale(slope: Float, intercept: Float) {
        uniforms.rescaleSlope = slope
        uniforms.rescaleIntercept = intercept
        syncUniforms()
    }

    func adjustWindowLevel(centerDelta: Float, widthDelta: Float) {
        uniforms.windowCenter += centerDelta
        uniforms.windowWidth = max(uniforms.windowWidth + widthDelta, 1.0)
        syncUniforms()
    }

    func setZoom(_ scale: Float) {
        uniforms.zoomScale = max(scale, 0.1)
        syncUniforms()
    }

    func adjustZoom(factor: Float) {
        uniforms.zoomScale = max(uniforms.zoomScale * factor, 0.1)
        syncUniforms()
    }

    func setPan(_ offset: SIMD2<Float>) {
        uniforms.panOffset = offset
        syncUniforms()
    }

    func adjustPan(dx: Float, dy: Float) {
        uniforms.panOffset.x += dx
        uniforms.panOffset.y += dy
        syncUniforms()
    }

    func resetView() {
        uniforms.zoomScale = 1.0
        uniforms.panOffset = .zero
        syncUniforms()
    }

    /// Current zoom scale (for coordinate conversion).
    var currentZoomScale: Float {
        uniforms.zoomScale
    }

    /// Current pan offset (for coordinate conversion).
    var currentPanOffset: SIMD2<Float> {
        uniforms.panOffset
    }

    // MARK: - Dynamic Texture

    func updateTexture(frameData: FrameData) {
        let width = frameData.width
        let height = frameData.height

        // Reuse texture if dimensions match
        if let existing = currentTexture,
           existing.width == width && existing.height == height {
            frameData.pixels.withUnsafeBufferPointer { ptr in
                existing.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: width * MemoryLayout<UInt16>.size)
            }
            return
        }

        // Create new texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        frameData.pixels.withUnsafeBufferPointer { ptr in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width * MemoryLayout<UInt16>.size)
        }

        currentTexture = texture
    }

    // MARK: - Test Pattern

    private func createTestTexture() {
        let width = 256
        let height = 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        var frame = DB_Frame16()
        let status = db_decode_frame16(nil, 0, &frame)

        if status == DB_STATUS_OK, let pixels = frame.pixels {
            texture.replace(
                region: MTLRegionMake2D(0, 0, Int(frame.width), Int(frame.height)),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: Int(frame.width) * MemoryLayout<UInt16>.size)
            db_free_buffer(pixels)
        }

        currentTexture = texture
    }

    enum RendererError: Error {
        case initializationFailed(String)
    }
}

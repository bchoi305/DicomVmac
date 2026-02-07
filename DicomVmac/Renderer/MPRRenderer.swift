//
//  MPRRenderer.swift
//  DicomVmac
//
//  Metal renderer for MPR (Multiplanar Reconstruction) views.
//  Uses a 3D texture for GPU-based volume sampling.
//

import Foundation
import Metal
import MetalKit

/// Swift mirror of the Metal MPRUniforms struct.
/// Must match layout in MPRShaders.metal exactly.
struct MPRUniforms {
    var windowCenter: Float = 40.0
    var windowWidth: Float = 400.0
    var rescaleSlope: Float = 1.0
    var rescaleIntercept: Float = -1024.0
    var zoomScale: Float = 1.0
    var panOffset: SIMD2<Float> = .zero
    var slicePosition: Float = 0.5
    var plane: Int32 = 0  // 0=axial, 1=coronal, 2=sagittal, 3=projection
    var crosshairPosition: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    var showCrosshair: Int32 = 1
    var renderMode: Int32 = 0       // 0=slice, 1=MIP, 2=MinIP, 3=AIP, 4=VR
    var numSamples: Int32 = 128     // Ray marching sample count
    var rotation: SIMD2<Float> = .zero  // Rotation angles (azimuth, elevation) for 3D projection
    var vrPreset: Int32 = 0         // VR transfer function preset
}

/// Renderer for a single MPR plane view.
final class MPRRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var uniformBuffer: MTLBuffer
    private var uniforms = MPRUniforms()

    // Pipeline states for each rendering mode
    private let slicePipelineState: MTLRenderPipelineState
    private let mipPipelineState: MTLRenderPipelineState
    private let minipPipelineState: MTLRenderPipelineState
    private let aipPipelineState: MTLRenderPipelineState
    private let vrPipelineState: MTLRenderPipelineState

    /// Current rendering mode.
    private(set) var renderMode: VolumeRenderMode = .slice

    /// Current VR preset.
    private(set) var vrPreset: VRPreset = .bone

    /// Number of samples for ray marching (projection modes).
    var numSamples: Int = 128 {
        didSet {
            uniforms.numSamples = Int32(numSamples)
            syncUniforms()
        }
    }

    /// The 3D volume texture (shared across all MPR views).
    private var volumeTexture: MTLTexture?

    /// Volume metadata for coordinate calculations.
    private(set) var volumeData: VolumeData?

    /// The plane this renderer displays.
    let plane: MPRPlane

    /// Callback when slice position changes (for crosshair sync).
    var onSliceChanged: ((Float) -> Void)?

    /// Callback when user clicks to update crosshair.
    var onCrosshairClicked: ((SIMD2<Float>) -> Void)?

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat, plane: MPRPlane) throws {
        self.device = device
        self.plane = plane

        guard let commandQueue = device.makeCommandQueue() else {
            throw MPRRendererError.initializationFailed("Cannot create command queue")
        }
        self.commandQueue = commandQueue

        // Create pipeline states for all rendering modes
        let vertexFunction = library.makeFunction(name: "mprVertexShader")

        func makePipeline(fragmentName: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = library.makeFunction(name: fragmentName)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            // Enable blending for VR compositing
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        self.slicePipelineState = try makePipeline(fragmentName: "mprFragmentShader")
        self.mipPipelineState = try makePipeline(fragmentName: "mipFragmentShader")
        self.minipPipelineState = try makePipeline(fragmentName: "minipFragmentShader")
        self.aipPipelineState = try makePipeline(fragmentName: "aipFragmentShader")
        self.vrPipelineState = try makePipeline(fragmentName: "vrFragmentShader")

        guard let buffer = device.makeBuffer(
            length: MemoryLayout<MPRUniforms>.stride,
            options: .storageModeShared
        ) else {
            throw MPRRendererError.initializationFailed("Cannot create uniform buffer")
        }
        self.uniformBuffer = buffer
        self.uniforms.plane = Int32(plane.rawValue)
        self.uniforms.numSamples = Int32(numSamples)

        super.init()
        syncUniforms()
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
                  descriptor: renderPassDescriptor),
              let volumeTexture = volumeTexture else {
            return
        }

        // Select pipeline based on render mode
        let pipelineState: MTLRenderPipelineState
        switch renderMode {
        case .slice:
            pipelineState = slicePipelineState
        case .mip:
            pipelineState = mipPipelineState
        case .minip:
            pipelineState = minipPipelineState
        case .aip:
            pipelineState = aipPipelineState
        case .vr:
            pipelineState = vrPipelineState
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(volumeTexture, index: 0)

        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Volume Loading

    /// Create a 3D texture from volume pixel data.
    func loadVolume(data: VolumeData, pixels: [UInt16]) {
        self.volumeData = data

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Uint
        descriptor.width = data.width
        descriptor.height = data.height
        descriptor.depth = data.depth
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            NSLog("[MPRRenderer] Failed to create 3D texture")
            return
        }

        pixels.withUnsafeBufferPointer { ptr in
            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: data.width, height: data.height, depth: data.depth)
                ),
                mipmapLevel: 0,
                slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: data.width * MemoryLayout<UInt16>.size,
                bytesPerImage: data.width * data.height * MemoryLayout<UInt16>.size
            )
        }

        self.volumeTexture = texture

        // Set initial uniforms from volume data
        uniforms.windowCenter = Float(data.windowCenter)
        uniforms.windowWidth = Float(data.windowWidth)
        uniforms.rescaleSlope = Float(data.rescaleSlope)
        uniforms.rescaleIntercept = Float(data.rescaleIntercept)
        syncUniforms()
    }

    /// Share an existing 3D texture (for multi-view setups).
    func setVolumeTexture(_ texture: MTLTexture, data: VolumeData) {
        self.volumeTexture = texture
        self.volumeData = data

        uniforms.windowCenter = Float(data.windowCenter)
        uniforms.windowWidth = Float(data.windowWidth)
        uniforms.rescaleSlope = Float(data.rescaleSlope)
        uniforms.rescaleIntercept = Float(data.rescaleIntercept)
        syncUniforms()
    }

    // MARK: - Uniform Updates

    private func syncUniforms() {
        uniformBuffer.contents().copyMemory(
            from: &uniforms,
            byteCount: MemoryLayout<MPRUniforms>.stride)
    }

    func setSlicePosition(_ position: Float) {
        uniforms.slicePosition = max(0.0, min(1.0, position))
        syncUniforms()
    }

    func adjustSlicePosition(delta: Float) {
        let newPosition = uniforms.slicePosition + delta
        setSlicePosition(newPosition)
        onSliceChanged?(uniforms.slicePosition)
    }

    var slicePosition: Float {
        uniforms.slicePosition
    }

    func setCrosshairPosition(_ position: SIMD2<Float>) {
        uniforms.crosshairPosition = position
        syncUniforms()
    }

    func setShowCrosshair(_ show: Bool) {
        uniforms.showCrosshair = show ? 1 : 0
        syncUniforms()
    }

    func setWindowLevel(center: Float, width: Float) {
        uniforms.windowCenter = center
        uniforms.windowWidth = max(width, 1.0)
        syncUniforms()
    }

    func adjustWindowLevel(centerDelta: Float, widthDelta: Float) {
        uniforms.windowCenter += centerDelta
        uniforms.windowWidth = max(uniforms.windowWidth + widthDelta, 1.0)
        syncUniforms()
    }

    var windowCenter: Float { uniforms.windowCenter }
    var windowWidth: Float { uniforms.windowWidth }

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
        uniforms.slicePosition = 0.5
        syncUniforms()
    }

    var currentZoomScale: Float { uniforms.zoomScale }
    var currentPanOffset: SIMD2<Float> { uniforms.panOffset }

    // MARK: - Render Mode

    /// Set the volume rendering mode.
    func setRenderMode(_ mode: VolumeRenderMode) {
        renderMode = mode
        uniforms.renderMode = Int32(mode.rawValue)
        syncUniforms()
    }

    /// Set the VR transfer function preset.
    func setVRPreset(_ preset: VRPreset) {
        vrPreset = preset
        uniforms.vrPreset = Int32(VRPreset.allCases.firstIndex(of: preset) ?? 0)
        syncUniforms()
    }

    /// Set rotation angles for 3D projection (azimuth, elevation in radians).
    func setRotation(_ rotation: SIMD2<Float>) {
        uniforms.rotation = rotation
        syncUniforms()
    }

    /// Adjust rotation angles (for mouse drag interaction).
    func adjustRotation(dAzimuth: Float, dElevation: Float) {
        uniforms.rotation.x += dAzimuth
        uniforms.rotation.y += dElevation
        // Clamp elevation to avoid flipping
        uniforms.rotation.y = max(-.pi / 2 + 0.01, min(.pi / 2 - 0.01, uniforms.rotation.y))
        syncUniforms()
    }

    var currentRotation: SIMD2<Float> { uniforms.rotation }

    // MARK: - Slice Information

    /// Get the current slice index (0-based) for display.
    func currentSliceIndex() -> Int {
        guard let data = volumeData else { return 0 }
        let depth: Int
        switch plane {
        case .axial: depth = data.depth
        case .coronal: depth = data.height
        case .sagittal: depth = data.width
        case .projection: return 0  // Projection doesn't have slices
        }
        return Int(uniforms.slicePosition * Float(depth - 1))
    }

    /// Get total number of slices for this plane.
    func totalSlices() -> Int {
        guard let data = volumeData else { return 0 }
        switch plane {
        case .axial: return data.depth
        case .coronal: return data.height
        case .sagittal: return data.width
        case .projection: return 0  // Projection doesn't have slices
        }
    }

    enum MPRRendererError: Error {
        case initializationFailed(String)
    }
}

// MARK: - Shared Volume Texture Manager

/// Manages a shared 3D volume texture for multiple MPR renderers.
final class MPRVolumeManager {

    private let device: MTLDevice
    private(set) var volumeTexture: MTLTexture?
    private(set) var volumeData: VolumeData?

    init(device: MTLDevice) {
        self.device = device
    }

    /// Load volume and create shared 3D texture.
    func loadVolume(data: VolumeData, pixels: [UInt16]) -> MTLTexture? {
        self.volumeData = data

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Uint
        descriptor.width = data.width
        descriptor.height = data.height
        descriptor.depth = data.depth
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            NSLog("[MPRVolumeManager] Failed to create 3D texture")
            return nil
        }

        pixels.withUnsafeBufferPointer { ptr in
            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: data.width, height: data.height, depth: data.depth)
                ),
                mipmapLevel: 0,
                slice: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: data.width * MemoryLayout<UInt16>.size,
                bytesPerImage: data.width * data.height * MemoryLayout<UInt16>.size
            )
        }

        self.volumeTexture = texture
        return texture
    }

    /// Clear the volume texture to free memory.
    func clear() {
        volumeTexture = nil
        volumeData = nil
    }
}

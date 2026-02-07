//
//  MPRPlaneView.swift
//  DicomVmac
//
//  A single MPR plane view that wraps an MTKView.
//  Handles scroll for slice navigation and click for crosshair updates.
//

import AppKit
import MetalKit

/// Delegate protocol for MPRPlaneView events.
@MainActor
protocol MPRPlaneViewDelegate: AnyObject {
    /// Called when the slice position changes (from scrolling).
    func planeView(_ view: MPRPlaneView, didChangeSlicePosition position: Float)

    /// Called when the user clicks to update the crosshair.
    func planeView(_ view: MPRPlaneView, didClickAtTextureCoord coord: SIMD2<Float>)

    /// Called when W/L changes (from option+drag).
    func planeView(_ view: MPRPlaneView, didChangeWindowLevel center: Float, width: Float)

    /// Called when rotation changes (projection view only).
    func planeView(_ view: MPRPlaneView, didChangeRotation rotation: SIMD2<Float>)
}

/// A view that displays a single MPR plane (Axial, Coronal, or Sagittal).
final class MPRPlaneView: NSView {

    weak var delegate: MPRPlaneViewDelegate?

    let plane: MPRPlane
    private(set) var mtkView: MTKView!
    private(set) var renderer: MPRRenderer?

    // Gesture state
    private var isOptionDragging = false
    private var lastDragPoint: NSPoint = .zero

    // Overlay labels
    private var planeLabel: NSTextField!
    private var sliceLabel: NSTextField!

    init(plane: MPRPlane, device: MTLDevice, library: MTLLibrary) {
        self.plane = plane
        super.init(frame: .zero)
        setupMTKView(device: device)
        setupRenderer(device: device, library: library)
        setupOverlayLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupMTKView(device: MTLDevice) {
        mtkView = MTKView(frame: bounds, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mtkView)

        NSLayoutConstraint.activate([
            mtkView.topAnchor.constraint(equalTo: topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: bottomAnchor),
            mtkView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func setupRenderer(device: MTLDevice, library: MTLLibrary) {
        do {
            renderer = try MPRRenderer(
                device: device,
                library: library,
                pixelFormat: mtkView.colorPixelFormat,
                plane: plane)
            mtkView.delegate = renderer
        } catch {
            NSLog("[MPRPlaneView] Failed to create renderer: %@", error.localizedDescription)
        }
    }

    private func setupOverlayLabels() {
        // Plane name label (top-left)
        planeLabel = makeOverlayLabel()
        planeLabel.stringValue = " \(plane.displayName) "
        addSubview(planeLabel)

        // Slice info label (bottom-right)
        sliceLabel = makeOverlayLabel()
        sliceLabel.stringValue = ""
        addSubview(sliceLabel)

        NSLayoutConstraint.activate([
            planeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            planeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            sliceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sliceLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    private func makeOverlayLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        label.isBezeled = false
        label.drawsBackground = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func updateSliceLabel() {
        guard let renderer = renderer else {
            sliceLabel.stringValue = ""
            return
        }

        // For projection view, show render mode instead of slice info
        if plane.supportsRotation {
            let modeName = renderer.renderMode.displayName
            if renderer.renderMode == .vr {
                sliceLabel.stringValue = " \(modeName): \(renderer.vrPreset.displayName) "
            } else {
                sliceLabel.stringValue = " \(modeName) "
            }
            return
        }

        let current = renderer.currentSliceIndex() + 1
        let total = renderer.totalSlices()
        sliceLabel.stringValue = " \(current) / \(total) "
    }

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer = renderer else { return }

        if event.modifierFlags.contains(.option) {
            // Option + scroll = WL/WW adjustment
            let deltaX = Float(event.scrollingDeltaX)
            let deltaY = Float(event.scrollingDeltaY)
            renderer.adjustWindowLevel(centerDelta: -deltaY * 2.0, widthDelta: deltaX * 2.0)
            delegate?.planeView(self, didChangeWindowLevel: renderer.windowCenter, width: renderer.windowWidth)
            mtkView.needsDisplay = true
            return
        }

        // For projection view, scroll = zoom
        if plane.supportsRotation {
            let delta = event.scrollingDeltaY
            let zoomFactor: Float = 1.0 + Float(delta) * 0.02
            renderer.adjustZoom(factor: zoomFactor)
            mtkView.needsDisplay = true
            return
        }

        // Regular scroll = slice navigation
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.3 else { return }

        let sliceDelta = delta > 0 ? -0.01 : 0.01
        renderer.adjustSlicePosition(delta: Float(sliceDelta))
        updateSliceLabel()
        delegate?.planeView(self, didChangeSlicePosition: renderer.slicePosition)
        mtkView.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        if event.clickCount == 2 {
            renderer?.resetView()
            updateSliceLabel()
            mtkView.needsDisplay = true
            return
        }

        let locationInView = convert(event.locationInWindow, from: nil)

        // Check for crosshair click (click without modifier)
        if !event.modifierFlags.contains(.option),
           let texCoord = screenToTextureCoord(locationInView) {
            delegate?.planeView(self, didClickAtTextureCoord: texCoord)
            return
        }

        lastDragPoint = event.locationInWindow
        isOptionDragging = event.modifierFlags.contains(.option)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let current = event.locationInWindow
        let dx = Float(current.x - lastDragPoint.x)
        let dy = Float(current.y - lastDragPoint.y)
        lastDragPoint = current

        if isOptionDragging {
            // Option + drag = WL/WW
            renderer.adjustWindowLevel(centerDelta: -dy, widthDelta: dx)
            delegate?.planeView(self, didChangeWindowLevel: renderer.windowCenter, width: renderer.windowWidth)
        } else if plane.supportsRotation {
            // Projection view: regular drag = rotate 3D view
            let rotationScale: Float = 0.01
            renderer.adjustRotation(dAzimuth: dx * rotationScale, dElevation: -dy * rotationScale)
            delegate?.planeView(self, didChangeRotation: renderer.currentRotation)
        } else {
            // Regular drag = pan
            let viewSize = bounds.size
            let panDx = dx / Float(viewSize.width) * 2.0
            let panDy = dy / Float(viewSize.height) * 2.0
            renderer.adjustPan(dx: panDx, dy: panDy)
        }
        mtkView.needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let scale = 1.0 + Float(event.magnification)
        renderer.adjustZoom(factor: scale)
        mtkView.needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let renderer = renderer else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 0x7E: // Up arrow
            renderer.adjustSlicePosition(delta: 0.01)
            updateSliceLabel()
            delegate?.planeView(self, didChangeSlicePosition: renderer.slicePosition)
            mtkView.needsDisplay = true
        case 0x7D: // Down arrow
            renderer.adjustSlicePosition(delta: -0.01)
            updateSliceLabel()
            delegate?.planeView(self, didChangeSlicePosition: renderer.slicePosition)
            mtkView.needsDisplay = true
        case 0x24: // Return - reset view
            renderer.resetView()
            updateSliceLabel()
            mtkView.needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Coordinate Conversion

    func screenToTextureCoord(_ screenPoint: NSPoint) -> SIMD2<Float>? {
        guard let renderer = renderer else { return nil }

        let viewSize = bounds.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return nil }

        // Convert to NDC (-1 to 1)
        let ndcX = Float(screenPoint.x / viewSize.width) * 2.0 - 1.0
        let ndcY = Float(screenPoint.y / viewSize.height) * 2.0 - 1.0

        // Reverse zoom/pan transform
        let zoomScale = renderer.currentZoomScale
        let panOffset = renderer.currentPanOffset

        let imageNdcX = (ndcX - panOffset.x) / zoomScale
        let imageNdcY = (ndcY - panOffset.y) / zoomScale

        // Convert to texture coordinates
        let texX = (imageNdcX + 1.0) * 0.5
        let texY = 1.0 - (imageNdcY + 1.0) * 0.5

        // Check bounds
        guard texX >= 0 && texX <= 1 && texY >= 0 && texY <= 1 else {
            return nil
        }

        return SIMD2<Float>(texX, texY)
    }
}

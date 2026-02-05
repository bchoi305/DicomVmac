//
//  ViewerViewController.swift
//  DicomVmac
//
//  Hosts the MTKView for GPU-accelerated DICOM image rendering.
//  Supports slice scrolling, WL/WW adjustment, zoom, and pan.
//

import AppKit
import MetalKit

final class ViewerViewController: NSViewController {

    private var mtkView: MTKView!
    private(set) var renderer: MetalRenderer?
    private let bridge = DicomBridgeWrapper()
    private let frameCache = FrameCache()
    private var prefetchManager: PrefetchManager?

    // Series navigation state
    private var currentSeries: Series?
    private var currentInstances: [Instance] = []
    private var currentSliceIndex: Int = 0
    private var lastScrollDelta: Int = 0

    // Overlay labels
    private var sliceLabel: NSTextField!
    private var infoLabel: NSTextField!

    // Gesture state
    private var isOptionDragging = false
    private var lastDragPoint: NSPoint = .zero

    // Annotation state
    let annotationManager = AnnotationManager()
    private let toolState = AnnotationToolState()
    private var previewPoints: [TexturePoint] = []
    private var previewTool: AnnotationTool = .none

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            let fallback = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let label = NSTextField(labelWithString: "Metal is not available on this device.")
            label.translatesAutoresizingMaskIntoConstraints = false
            fallback.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: fallback.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: fallback.centerYAnchor)
            ])
            view = fallback
            return
        }

        mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        view = mtkView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Viewer"

        guard let mtkView = mtkView else { return }

        do {
            renderer = try MetalRenderer(metalView: mtkView)
            mtkView.delegate = renderer
        } catch {
            NSLog("[DicomVmac] Failed to initialize Metal renderer: %@",
                  error.localizedDescription)
        }

        prefetchManager = PrefetchManager(cache: frameCache, bridge: bridge)
        setupOverlayLabels()
        setupAnnotationCallbacks()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Enable mouse moved events for annotation preview
        view.window?.acceptsMouseMovedEvents = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    // MARK: - Overlay Labels

    private func setupOverlayLabels() {
        // Slice indicator (bottom-right)
        sliceLabel = makeOverlayLabel()
        sliceLabel.stringValue = ""
        view.addSubview(sliceLabel)

        // Info label (top-left)
        infoLabel = makeOverlayLabel()
        infoLabel.stringValue = ""
        view.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            sliceLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            sliceLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            infoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
        ])
    }

    private func makeOverlayLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        label.isBezeled = false
        label.drawsBackground = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func updateSliceLabel() {
        guard !currentInstances.isEmpty else {
            sliceLabel.stringValue = ""
            return
        }
        sliceLabel.stringValue = " \(currentSliceIndex + 1) / \(currentInstances.count) "
    }

    private func updateInfoLabel() {
        guard let series = currentSeries else {
            infoLabel.stringValue = ""
            return
        }
        let parts = [
            series.modality,
            series.seriesDescription
        ].compactMap { $0 }.filter { !$0.isEmpty }
        infoLabel.stringValue = parts.isEmpty ? "" : " \(parts.joined(separator: " — ")) "
    }

    // MARK: - Series Loading

    func loadSeries(_ series: Series) {
        guard let dbManager = AppDelegate.shared.databaseManager else { return }

        do {
            let instances = try dbManager.fetchInstances(forSeries: series.id!)
            guard !instances.isEmpty else { return }

            currentSeries = series
            currentInstances = instances
            currentSliceIndex = 0
            lastScrollDelta = 0

            updateInfoLabel()
            loadSlice(at: 0)
        } catch {
            NSLog("[Viewer] Failed to load series instances: %@",
                  error.localizedDescription)
        }
    }

    private func loadSlice(at index: Int) {
        guard index >= 0 && index < currentInstances.count else { return }
        currentSliceIndex = index
        toolState.setSliceIndex(index)
        updateSliceLabel()
        updateAnnotations()

        let instance = currentInstances[index]
        let seriesRowID = currentSeries!.id!
        let key = FrameCacheKey(seriesRowID: seriesRowID, instanceIndex: index)

        Task {
            do {
                let frame = try await frameCache.getOrDecode(key: key) { [bridge] in
                    try bridge.decodeFrame(filePath: instance.filePath)
                }

                await MainActor.run {
                    renderer?.updateTexture(frameData: frame)
                    renderer?.setWindowLevel(
                        center: Float(frame.windowCenter),
                        width: Float(frame.windowWidth))
                    renderer?.setRescale(
                        slope: Float(frame.rescaleSlope),
                        intercept: Float(frame.rescaleIntercept))
                    mtkView?.needsDisplay = true
                }

                // Trigger prefetch
                await prefetchManager?.prefetch(
                    around: index,
                    seriesRowID: seriesRowID,
                    instances: currentInstances,
                    scrollDelta: lastScrollDelta)
            } catch {
                NSLog("[Viewer] Failed to decode slice %d: %@",
                      index, error.localizedDescription)
            }
        }
    }

    // MARK: - Scroll Wheel (Slice Navigation + Option = WL/WW)

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            // Option + scroll → WL/WW adjustment
            guard let renderer = renderer else { return }
            let deltaX = Float(event.scrollingDeltaX)
            let deltaY = Float(event.scrollingDeltaY)
            renderer.adjustWindowLevel(centerDelta: -deltaY * 2.0,
                                       widthDelta: deltaX * 2.0)
            mtkView?.needsDisplay = true
            return
        }

        // Regular scroll → slice navigation
        guard !currentInstances.isEmpty else { return }

        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.5 else { return }

        let direction = delta > 0 ? -1 : 1
        lastScrollDelta = direction
        let newIndex = max(0, min(currentInstances.count - 1,
                                  currentSliceIndex + direction))
        if newIndex != currentSliceIndex {
            loadSlice(at: newIndex)
        }
    }

    // MARK: - Mouse Events (Pan + Option+Drag for WL/WW + Annotations)

    override func mouseDown(with event: NSEvent) {
        // Convert to view coordinates
        let locationInView = view.convert(event.locationInWindow, from: nil)

        // Handle annotation tool input
        if toolState.currentTool != .none {
            if let texCoord = screenToTextureCoord(locationInView) {
                if toolState.currentTool == .ellipseROI {
                    toolState.handleDragStart(at: texCoord)
                } else {
                    toolState.handleClick(at: texCoord)
                }
                return
            }
        }

        // Hit test for selection in view mode
        if toolState.currentTool == .none, let series = currentSeries {
            if let texCoord = screenToTextureCoord(locationInView) {
                if let hitID = annotationManager.hitTest(
                    textureCoord: texCoord,
                    seriesID: series.id!,
                    sliceIndex: currentSliceIndex
                ) {
                    annotationManager.selectAnnotation(id: hitID, seriesID: series.id!)
                    updateAnnotations()
                    return
                } else {
                    // Click on empty space — deselect
                    annotationManager.clearSelection()
                    updateAnnotations()
                }
            }
        }

        if event.clickCount == 2 {
            renderer?.resetView()
            mtkView?.needsDisplay = true
            return
        }

        lastDragPoint = event.locationInWindow
        isOptionDragging = event.modifierFlags.contains(.option)
    }

    override func mouseDragged(with event: NSEvent) {
        // Handle ellipse drag
        if toolState.currentTool == .ellipseROI && toolState.isDrawing {
            let locationInView = view.convert(event.locationInWindow, from: nil)
            if let texCoord = screenToTextureCoord(locationInView) {
                toolState.handleDrag(to: texCoord)
            }
            return
        }

        guard let renderer = renderer else { return }
        let current = event.locationInWindow
        let dx = Float(current.x - lastDragPoint.x)
        let dy = Float(current.y - lastDragPoint.y)
        lastDragPoint = current

        if isOptionDragging {
            // Option + drag → WL/WW
            renderer.adjustWindowLevel(centerDelta: -dy, widthDelta: dx)
        } else {
            // Regular drag → pan
            let viewSize = view.bounds.size
            let panDx = dx / Float(viewSize.width) * 2.0
            let panDy = dy / Float(viewSize.height) * 2.0
            renderer.adjustPan(dx: panDx, dy: panDy)
        }
        mtkView?.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Handle ellipse completion
        if toolState.currentTool == .ellipseROI && toolState.isDrawing {
            let locationInView = view.convert(event.locationInWindow, from: nil)
            if let texCoord = screenToTextureCoord(locationInView) {
                toolState.handleDragEnd(at: texCoord)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        // Update preview for rubber-banding
        guard toolState.isDrawing else { return }

        let locationInView = view.convert(event.locationInWindow, from: nil)
        if let texCoord = screenToTextureCoord(locationInView) {
            toolState.handleMove(to: texCoord)
        }
    }

    // MARK: - Magnification (Pinch Zoom)

    override func magnify(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let scale = 1.0 + Float(event.magnification)
        renderer.adjustZoom(factor: scale)
        mtkView?.needsDisplay = true
    }

    // MARK: - Keyboard Shortcuts

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x7B: // Left arrow
            if currentSliceIndex > 0 {
                lastScrollDelta = -1
                loadSlice(at: currentSliceIndex - 1)
            }
        case 0x7C: // Right arrow
            if currentSliceIndex < currentInstances.count - 1 {
                lastScrollDelta = 1
                loadSlice(at: currentSliceIndex + 1)
            }
        case 0x24: // Return — reset view
            renderer?.resetView()
            mtkView?.needsDisplay = true
        case 0x35: // Escape — cancel annotation or switch to view mode
            if toolState.isDrawing {
                toolState.cancel()
            } else {
                setAnnotationTool(.none)
            }
        case 0x33: // Delete — delete selected annotation
            deleteSelectedAnnotation()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Annotation Support

    private func setupAnnotationCallbacks() {
        toolState.onAnnotationComplete = { [weak self] annotation in
            guard let self, let series = currentSeries else { return }
            annotationManager.addAnnotation(annotation, seriesID: series.id!)
            updateAnnotations()
        }

        toolState.onPreviewUpdate = { [weak self] points, tool in
            self?.previewPoints = points
            self?.previewTool = tool
            self?.updateAnnotations()
        }

        toolState.onCancel = { [weak self] in
            self?.previewPoints = []
            self?.updateAnnotations()
        }
    }

    /// Set the current annotation tool.
    func setAnnotationTool(_ tool: AnnotationTool) {
        toolState.setTool(tool)
        previewPoints = []
        updateAnnotations()
    }

    /// Get the current annotation tool.
    var currentAnnotationTool: AnnotationTool {
        toolState.currentTool
    }

    /// Delete the currently selected annotation.
    func deleteSelectedAnnotation() {
        annotationManager.deleteSelectedAnnotation()
        updateAnnotations()
    }

    /// Update annotations on the renderer.
    private func updateAnnotations() {
        guard let series = currentSeries else {
            renderer?.annotations = []
            renderer?.selectedAnnotationID = nil
            mtkView?.needsDisplay = true
            return
        }

        var annotations = annotationManager.annotations(forSeries: series.id!, slice: currentSliceIndex)

        // Add preview annotation if drawing
        if !previewPoints.isEmpty {
            let previewAnnotation = createPreviewAnnotation()
            if let preview = previewAnnotation {
                annotations.append(preview)
            }
        }

        renderer?.annotations = annotations
        renderer?.selectedAnnotationID = annotationManager.selectedAnnotationID
        mtkView?.needsDisplay = true
    }

    private func createPreviewAnnotation() -> AnyAnnotation? {
        switch previewTool {
        case .none:
            return nil
        case .length:
            guard previewPoints.count >= 2 else { return nil }
            return .length(LengthAnnotation(
                sliceIndex: currentSliceIndex,
                startPoint: previewPoints[0],
                endPoint: previewPoints[1]))
        case .angle:
            guard previewPoints.count >= 2 else { return nil }
            if previewPoints.count == 2 {
                // Show first arm only
                return .length(LengthAnnotation(
                    sliceIndex: currentSliceIndex,
                    startPoint: previewPoints[0],
                    endPoint: previewPoints[1]))
            } else {
                return .angle(AngleAnnotation(
                    sliceIndex: currentSliceIndex,
                    pointA: previewPoints[0],
                    vertex: previewPoints[1],
                    pointC: previewPoints[2]))
            }
        case .polygonROI:
            guard previewPoints.count >= 2 else { return nil }
            return .roi(ROIAnnotation(
                sliceIndex: currentSliceIndex,
                points: previewPoints,
                isClosed: false))
        case .ellipseROI:
            guard previewPoints.count == 2 else { return nil }
            let center = previewPoints[0]
            let edge = previewPoints[1]
            return .ellipse(EllipseROIAnnotation(
                sliceIndex: currentSliceIndex,
                center: center,
                radiusX: abs(edge.x - center.x),
                radiusY: abs(edge.y - center.y)))
        }
    }

    // MARK: - Coordinate Conversion

    /// Convert screen coordinates to texture coordinates (0-1 range).
    /// Returns nil if the point is outside the image bounds.
    func screenToTextureCoord(_ screenPoint: NSPoint) -> TexturePoint? {
        guard let renderer = renderer else { return nil }

        let viewSize = view.bounds.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return nil }

        // Convert to NDC (-1 to 1)
        let ndcX = Float(screenPoint.x / viewSize.width) * 2.0 - 1.0
        let ndcY = Float(screenPoint.y / viewSize.height) * 2.0 - 1.0

        // Reverse the zoom/pan transform
        let zoomScale = renderer.currentZoomScale
        let panOffset = renderer.currentPanOffset

        let imageNdcX = (ndcX - panOffset.x) / zoomScale
        let imageNdcY = (ndcY - panOffset.y) / zoomScale

        // Convert NDC to texture coordinates
        // NDC: (-1,-1) is bottom-left, (1,1) is top-right
        // Texture: (0,0) is top-left, (1,1) is bottom-right
        let texX = (imageNdcX + 1.0) * 0.5
        let texY = 1.0 - (imageNdcY + 1.0) * 0.5

        // Check bounds
        guard texX >= 0 && texX <= 1 && texY >= 0 && texY <= 1 else {
            return nil
        }

        return TexturePoint(x: texX, y: texY)
    }
}

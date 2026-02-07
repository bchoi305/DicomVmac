//
//  MPRViewerViewController.swift
//  DicomVmac
//
//  Container view controller for MPR visualization.
//  Manages three plane views (Axial, Coronal, Sagittal) with synchronized crosshairs.
//

import AppKit
import MetalKit

final class MPRViewerViewController: NSViewController {

    private var axialView: MPRPlaneView!
    private var coronalView: MPRPlaneView!
    private var sagittalView: MPRPlaneView!
    private var projectionView: MPRPlaneView!  // 3D projection view (replaces info panel)

    private var volumeManager: MPRVolumeManager?
    private var volumeData: VolumeData?

    /// Current slice positions (normalized 0-1).
    private var slicePosition = MPRSlicePosition.center

    /// Current render mode for projection view.
    private(set) var renderMode: VolumeRenderMode = .mip

    /// Current VR preset.
    private(set) var vrPreset: VRPreset = .bone

    /// Loading indicator.
    private var progressIndicator: NSProgressIndicator?
    private var loadingLabel: NSTextField?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary() else {
            showError("Metal is not available on this device.")
            return
        }

        volumeManager = MPRVolumeManager(device: device)
        setupPlaneViews(device: device, library: library)
        setupLayout()
        setupLoadingUI()
    }

    // MARK: - Setup

    private func setupPlaneViews(device: MTLDevice, library: MTLLibrary) {
        axialView = MPRPlaneView(plane: .axial, device: device, library: library)
        axialView.delegate = self

        coronalView = MPRPlaneView(plane: .coronal, device: device, library: library)
        coronalView.delegate = self

        sagittalView = MPRPlaneView(plane: .sagittal, device: device, library: library)
        sagittalView.delegate = self

        projectionView = MPRPlaneView(plane: .projection, device: device, library: library)
        projectionView.delegate = self
        // Set projection view to MIP mode by default
        projectionView.renderer?.setRenderMode(.mip)

        [axialView, coronalView, sagittalView, projectionView].forEach {
            $0?.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0!)
        }
    }

    private func setupLayout() {
        // 2x2 grid layout
        let padding: CGFloat = 2

        NSLayoutConstraint.activate([
            // Top row: Axial (left), Sagittal (right)
            axialView.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            axialView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            axialView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5, constant: -padding * 1.5),
            axialView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5, constant: -padding * 1.5),

            sagittalView.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            sagittalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            sagittalView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5, constant: -padding * 1.5),
            sagittalView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5, constant: -padding * 1.5),

            // Bottom row: Coronal (left), 3D Projection (right)
            coronalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding),
            coronalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            coronalView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5, constant: -padding * 1.5),
            coronalView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5, constant: -padding * 1.5),

            projectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding),
            projectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            projectionView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5, constant: -padding * 1.5),
            projectionView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5, constant: -padding * 1.5)
        ])
    }

    private func setupLoadingUI() {
        progressIndicator = NSProgressIndicator()
        progressIndicator?.style = .spinning
        progressIndicator?.controlSize = .regular
        progressIndicator?.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator?.isHidden = true
        view.addSubview(progressIndicator!)

        loadingLabel = NSTextField(labelWithString: "Loading volume...")
        loadingLabel?.textColor = .white
        loadingLabel?.font = .systemFont(ofSize: 13)
        loadingLabel?.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel?.isHidden = true
        view.addSubview(loadingLabel!)

        NSLayoutConstraint.activate([
            progressIndicator!.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressIndicator!.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadingLabel!.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingLabel!.topAnchor.constraint(equalTo: progressIndicator!.bottomAnchor, constant: 12)
        ])
    }

    private func showError(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.textColor = .systemRed
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Volume Loading

    func loadSeries(_ series: Series) {
        guard let dbManager = AppDelegate.shared.databaseManager else { return }

        do {
            let instances = try dbManager.fetchInstances(forSeries: series.id!)
            loadVolume(series: series, instances: instances)
        } catch {
            NSLog("[MPRViewer] Failed to fetch instances: %@", error.localizedDescription)
        }
    }

    func loadVolume(series: Series, instances: [Instance]) {
        showLoading(true)

        Task {
            do {
                let loader = VolumeLoader()
                let (volumeData, pixels) = try await loader.loadVolume(
                    series: series,
                    instances: instances
                ) { [weak self] loaded, total in
                    Task { @MainActor in
                        self?.loadingLabel?.stringValue = "Loading slice \(loaded) of \(total)..."
                    }
                }

                await MainActor.run {
                    self.volumeData = volumeData
                    self.setupVolumeTexture(data: volumeData, pixels: pixels)
                    self.showLoading(false)
                    self.updateAllViews()
                }
            } catch {
                await MainActor.run {
                    self.showLoading(false)
                    NSLog("[MPRViewer] Failed to load volume: %@", error.localizedDescription)
                }
            }
        }
    }

    private func setupVolumeTexture(data: VolumeData, pixels: [UInt16]) {
        guard let texture = volumeManager?.loadVolume(data: data, pixels: pixels) else {
            return
        }

        // Share the texture with all renderers
        axialView.renderer?.setVolumeTexture(texture, data: data)
        coronalView.renderer?.setVolumeTexture(texture, data: data)
        sagittalView.renderer?.setVolumeTexture(texture, data: data)
        projectionView.renderer?.setVolumeTexture(texture, data: data)

        // Set initial slice positions to center
        slicePosition = .center
        syncSlicePositions()
    }

    private func showLoading(_ show: Bool) {
        progressIndicator?.isHidden = !show
        loadingLabel?.isHidden = !show
        if show {
            progressIndicator?.startAnimation(nil)
        } else {
            progressIndicator?.stopAnimation(nil)
        }
    }

    // MARK: - Crosshair Synchronization

    private func syncSlicePositions() {
        axialView.renderer?.setSlicePosition(slicePosition.axial)
        coronalView.renderer?.setSlicePosition(slicePosition.coronal)
        sagittalView.renderer?.setSlicePosition(slicePosition.sagittal)
    }

    private func updateCrosshairs() {
        // Axial view: crosshair at (sagittal, coronal) position
        axialView.renderer?.setCrosshairPosition(SIMD2<Float>(slicePosition.sagittal, slicePosition.coronal))

        // Coronal view: crosshair at (sagittal, axial) position
        coronalView.renderer?.setCrosshairPosition(SIMD2<Float>(slicePosition.sagittal, slicePosition.axial))

        // Sagittal view: crosshair at (coronal, axial) position
        sagittalView.renderer?.setCrosshairPosition(SIMD2<Float>(slicePosition.coronal, slicePosition.axial))
    }

    private func updateAllViews() {
        syncSlicePositions()
        updateCrosshairs()

        axialView.updateSliceLabel()
        coronalView.updateSliceLabel()
        sagittalView.updateSliceLabel()
        projectionView.updateSliceLabel()

        axialView.mtkView.needsDisplay = true
        coronalView.mtkView.needsDisplay = true
        sagittalView.mtkView.needsDisplay = true
        projectionView.mtkView.needsDisplay = true
    }

    // MARK: - Window/Level Synchronization

    func setWindowLevel(center: Float, width: Float) {
        axialView.renderer?.setWindowLevel(center: center, width: width)
        coronalView.renderer?.setWindowLevel(center: center, width: width)
        sagittalView.renderer?.setWindowLevel(center: center, width: width)
        projectionView.renderer?.setWindowLevel(center: center, width: width)
        updateAllViews()
    }

    // MARK: - Render Mode Control

    /// Set the render mode for the 3D projection view.
    func setRenderMode(_ mode: VolumeRenderMode) {
        renderMode = mode
        projectionView.renderer?.setRenderMode(mode)
        projectionView.updateSliceLabel()
        projectionView.mtkView.needsDisplay = true
    }

    /// Set the VR preset for volume rendering.
    func setVRPreset(_ preset: VRPreset) {
        vrPreset = preset
        projectionView.renderer?.setVRPreset(preset)
        projectionView.updateSliceLabel()
        projectionView.mtkView.needsDisplay = true
    }
}

// MARK: - MPRPlaneViewDelegate

extension MPRViewerViewController: MPRPlaneViewDelegate {

    func planeView(_ view: MPRPlaneView, didChangeSlicePosition position: Float) {
        switch view.plane {
        case .axial:
            slicePosition.axial = position
        case .coronal:
            slicePosition.coronal = position
        case .sagittal:
            slicePosition.sagittal = position
        case .projection:
            // Projection view doesn't have slice position
            return
        }
        updateCrosshairs()

        // Refresh other views to show updated crosshair
        if view !== axialView { axialView.mtkView.needsDisplay = true }
        if view !== coronalView { coronalView.mtkView.needsDisplay = true }
        if view !== sagittalView { sagittalView.mtkView.needsDisplay = true }
    }

    func planeView(_ view: MPRPlaneView, didClickAtTextureCoord coord: SIMD2<Float>) {
        // Click in one view updates slice positions in other two views
        switch view.plane {
        case .axial:
            // Click at (x, y) in axial → x sets sagittal, y sets coronal
            slicePosition.sagittal = coord.x
            slicePosition.coronal = coord.y
        case .coronal:
            // Click at (x, y) in coronal → x sets sagittal, y sets axial
            slicePosition.sagittal = coord.x
            slicePosition.axial = coord.y
        case .sagittal:
            // Click at (x, y) in sagittal → x sets coronal, y sets axial
            slicePosition.coronal = coord.x
            slicePosition.axial = coord.y
        case .projection:
            // Projection view doesn't update crosshairs
            return
        }

        updateAllViews()
    }

    func planeView(_ view: MPRPlaneView, didChangeWindowLevel center: Float, width: Float) {
        // Sync W/L across all views
        if view !== axialView {
            axialView.renderer?.setWindowLevel(center: center, width: width)
            axialView.mtkView.needsDisplay = true
        }
        if view !== coronalView {
            coronalView.renderer?.setWindowLevel(center: center, width: width)
            coronalView.mtkView.needsDisplay = true
        }
        if view !== sagittalView {
            sagittalView.renderer?.setWindowLevel(center: center, width: width)
            sagittalView.mtkView.needsDisplay = true
        }
        if view !== projectionView {
            projectionView.renderer?.setWindowLevel(center: center, width: width)
            projectionView.mtkView.needsDisplay = true
        }
    }

    func planeView(_ view: MPRPlaneView, didChangeRotation rotation: SIMD2<Float>) {
        // Rotation only applies to projection view, nothing to sync
    }
}

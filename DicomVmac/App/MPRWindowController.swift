//
//  MPRWindowController.swift
//  DicomVmac
//
//  Window controller for MPR (Multiplanar Reconstruction) viewer.
//  Creates a dedicated window with the 2x2 MPR view layout.
//

import AppKit

final class MPRWindowController: NSWindowController {

    private var mprViewController: MPRViewerViewController!

    init(series: Series, instances: [Instance]) {
        let contentRect = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable
        ]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        let seriesDesc = series.seriesDescription ?? "Series \(series.seriesNumber ?? 0)"
        window.title = "MPR — \(seriesDesc)"
        window.setFrameAutosaveName("MPRWindow")
        window.center()
        window.minSize = NSSize(width: 800, height: 600)

        super.init(window: window)

        setupViewController(series: series, instances: instances)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViewController(series: Series, instances: [Instance]) {
        mprViewController = MPRViewerViewController()
        window?.contentViewController = mprViewController

        // Load volume after view is set up
        DispatchQueue.main.async { [weak self] in
            self?.mprViewController.loadVolume(series: series, instances: instances)
        }
    }

    /// Open MPR window for a series.
    static func openMPR(for series: Series) {
        guard let dbManager = AppDelegate.shared.databaseManager else {
            NSLog("[MPRWindowController] No database manager available")
            return
        }

        do {
            let instances = try dbManager.fetchInstances(forSeries: series.id!)

            guard instances.count >= 3 else {
                let alert = NSAlert()
                alert.messageText = "Cannot Open MPR"
                alert.informativeText = "MPR requires at least 3 slices. This series has \(instances.count) slice(s)."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            let windowController = MPRWindowController(series: series, instances: instances)
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)

            // Keep a reference to prevent deallocation
            AppDelegate.shared.registerMPRWindow(windowController)
        } catch {
            NSLog("[MPRWindowController] Failed to load instances: %@", error.localizedDescription)
        }
    }
}

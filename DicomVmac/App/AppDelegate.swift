//
//  AppDelegate.swift
//  DicomVmac
//
//  Application entry point. Creates the main window programmatically.
//

import AppKit

/// Notification posted when folder indexing completes and sidebar should refresh.
extension Notification.Name {
    static let dicomDatabaseDidUpdate = Notification.Name("dicomDatabaseDidUpdate")
    static let dicomSeriesDidSelect = Notification.Name("dicomSeriesDidSelect")
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private(set) var databaseManager: DatabaseManager?
    private(set) var bridge = DicomBridgeWrapper()
    private var mprWindows: [MPRWindowController] = []

    /// Shared instance accessible from other parts of the app.
    @MainActor static var shared: AppDelegate {
        NSApplication.shared.delegate as! AppDelegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        // Initialize database
        let dbPath = Self.databasePath()
        do {
            databaseManager = try DatabaseManager(path: dbPath)
            NSLog("[DicomVmac] Database opened at: %@", dbPath)
        } catch {
            NSLog("[DicomVmac] Failed to open database: %@",
                  error.localizedDescription)
        }

        let windowController = MainWindowController()
        windowController.showWindow(nil)
        mainWindowController = windowController

        NSLog("[DicomVmac] Application launched. DicomCore version: %@",
              String(cString: db_version()))
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DicomVmac", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dicom_index.sqlite").path
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[DicomVmac] Application terminating.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DicomVmac",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DicomVmac",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Folder...",
                         action: #selector(openFolder(_:)),
                         keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Import DICOMDIR...",
                         action: #selector(importDicomdir(_:)),
                         keyEquivalent: "d")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Export...",
                         action: #selector(exportImages(_:)),
                         keyEquivalent: "e")
        fileMenu.addItem(withTitle: "Anonymize...",
                         action: #selector(anonymizeImages(_:)),
                         keyEquivalent: "")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Network menu
        let networkMenuItem = NSMenuItem()
        let networkMenu = NSMenu(title: "Network")
        networkMenu.addItem(withTitle: "PACS Nodes...",
                           action: #selector(showPreferences(_:)),
                           keyEquivalent: ",")
        networkMenu.addItem(withTitle: "Query/Retrieve...",
                           action: #selector(showQueryDialog(_:)),
                           keyEquivalent: "f")
        networkMenuItem.submenu = networkMenu
        mainMenu.addItem(networkMenuItem)

        // Measure menu
        let measureMenuItem = NSMenuItem()
        let measureMenu = NSMenu(title: "Measure")
        measureMenu.addItem(withTitle: "View Mode",
                            action: #selector(setToolNone(_:)),
                            keyEquivalent: "\u{1B}") // Escape
        measureMenu.addItem(NSMenuItem.separator())
        measureMenu.addItem(withTitle: "Length Tool",
                            action: #selector(setToolLength(_:)),
                            keyEquivalent: "l")
        measureMenu.addItem(withTitle: "Angle Tool",
                            action: #selector(setToolAngle(_:)),
                            keyEquivalent: "a")
        measureMenu.addItem(withTitle: "Polygon ROI",
                            action: #selector(setToolPolygonROI(_:)),
                            keyEquivalent: "r")
        measureMenu.addItem(withTitle: "Ellipse ROI",
                            action: #selector(setToolEllipseROI(_:)),
                            keyEquivalent: "e")
        measureMenu.addItem(NSMenuItem.separator())
        measureMenu.addItem(withTitle: "Delete Selected",
                            action: #selector(deleteSelectedAnnotation(_:)),
                            keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
        measureMenuItem.submenu = measureMenu
        mainMenu.addItem(measureMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Open in MPR",
                         action: #selector(openInMPR(_:)),
                         keyEquivalent: "m")
        viewMenu.addItem(NSMenuItem.separator())

        // Render Mode submenu
        let renderModeItem = NSMenuItem(title: "Render Mode", action: nil, keyEquivalent: "")
        let renderModeMenu = NSMenu(title: "Render Mode")
        for mode in VolumeRenderMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(setRenderMode(_:)),
                keyEquivalent: "")
            item.tag = mode.rawValue
            renderModeMenu.addItem(item)
        }
        renderModeMenu.delegate = self
        renderModeItem.submenu = renderModeMenu
        viewMenu.addItem(renderModeItem)

        // VR Preset submenu
        let vrPresetItem = NSMenuItem(title: "VR Preset", action: nil, keyEquivalent: "")
        let vrPresetMenu = NSMenu(title: "VR Preset")
        for (index, preset) in VRPreset.allCases.enumerated() {
            let item = NSMenuItem(
                title: preset.displayName,
                action: #selector(setVRPreset(_:)),
                keyEquivalent: "")
            item.tag = index
            vrPresetMenu.addItem(item)
        }
        vrPresetMenu.delegate = self
        vrPresetItem.submenu = vrPresetMenu
        viewMenu.addItem(vrPresetItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Layout menu
        let layoutMenuItem = NSMenuItem()
        let layoutMenu = NSMenu(title: "Layout")
        for layout in HangingProtocol.layouts {
            let item = NSMenuItem(
                title: layout.name,
                action: #selector(setLayout(_:)),
                keyEquivalent: layout.keyEquivalent ?? "")
            item.representedObject = layout
            layoutMenu.addItem(item)
        }
        layoutMenu.addItem(NSMenuItem.separator())
        layoutMenu.addItem(withTitle: "Link Viewers",
                           action: #selector(toggleLinking(_:)),
                           keyEquivalent: "")
        layoutMenu.delegate = self
        layoutMenuItem.submenu = layoutMenu
        mainMenu.addItem(layoutMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    // MARK: - Measure Menu Actions

    @objc private func setToolNone(_ sender: Any?) {
        mainWindowController?.setAnnotationTool(.none)
    }

    @objc private func setToolLength(_ sender: Any?) {
        mainWindowController?.setAnnotationTool(.length)
    }

    @objc private func setToolAngle(_ sender: Any?) {
        mainWindowController?.setAnnotationTool(.angle)
    }

    @objc private func setToolPolygonROI(_ sender: Any?) {
        mainWindowController?.setAnnotationTool(.polygonROI)
    }

    @objc private func setToolEllipseROI(_ sender: Any?) {
        mainWindowController?.setAnnotationTool(.ellipseROI)
    }

    @objc private func deleteSelectedAnnotation(_ sender: Any?) {
        mainWindowController?.deleteSelectedAnnotation()
    }

    @objc private func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true  // Allow selecting DICOMDIR files directly
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder or DICOMDIR file"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.importPath(url.path)
            }
        }
    }

    @objc private func importDicomdir(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a DICOMDIR file or folder containing one"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.importDicomdirAt(url.path)
            }
        }
    }

    /// Smart import: auto-detect DICOMDIR vs regular folder.
    func importPath(_ path: String) {
        if bridge.isDicomdir(path: path) {
            importDicomdirAt(path)
        } else {
            indexFolder(at: path)
        }
    }

    func indexFolder(at path: String) {
        guard let dbManager = databaseManager else { return }
        NSLog("[DicomVmac] Indexing folder: %@", path)
        let bridge = self.bridge

        Task.detached {
            do {
                try await dbManager.indexFolder(path: path, bridge: bridge) { scanned, found in
                    NSLog("[DicomVmac] Scan progress: %d scanned, %d DICOM files found",
                          scanned, found)
                }
                await MainActor.run {
                    NSLog("[DicomVmac] Indexing complete for: %@", path)
                    NotificationCenter.default.post(
                        name: .dicomDatabaseDidUpdate, object: nil)
                }
            } catch {
                NSLog("[DicomVmac] Indexing failed: %@", error.localizedDescription)
            }
        }
    }

    /// Import from DICOMDIR specifically.
    func importDicomdirAt(_ path: String) {
        guard let dbManager = databaseManager else { return }
        NSLog("[DicomVmac] Importing DICOMDIR: %@", path)
        let bridge = self.bridge

        Task.detached {
            do {
                try await dbManager.indexDicomdir(path: path, bridge: bridge) { processed, found in
                    NSLog("[DicomVmac] DICOMDIR progress: %d records, %d files found",
                          processed, found)
                }
                await MainActor.run {
                    NSLog("[DicomVmac] DICOMDIR import complete: %@", path)
                    NotificationCenter.default.post(
                        name: .dicomDatabaseDidUpdate, object: nil)
                }
            } catch {
                NSLog("[DicomVmac] DICOMDIR import failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - MPR Support

    @objc private func openInMPR(_ sender: Any?) {
        // This will be triggered via menu; the sidebar handles selection
        NotificationCenter.default.post(name: .dicomOpenInMPR, object: nil)
    }

    /// Register an MPR window to keep it alive.
    func registerMPRWindow(_ controller: MPRWindowController) {
        mprWindows.append(controller)

        // Clean up closed windows
        mprWindows.removeAll { $0.window == nil || !$0.window!.isVisible }
    }

    // MARK: - Layout Actions

    @objc private func setLayout(_ sender: NSMenuItem) {
        guard let layout = sender.representedObject as? HangingProtocol else { return }
        mainWindowController?.setLayout(layout)
    }

    @objc private func toggleLinking(_ sender: Any?) {
        mainWindowController?.toggleLinking()
    }

    // MARK: - Render Mode Actions

    /// Get the currently active MPR viewer controller.
    private var activeMPRViewer: MPRViewerViewController? {
        // Check if the key window is an MPR window
        if let mprWindow = mprWindows.first(where: { $0.window?.isKeyWindow == true }),
           let viewer = mprWindow.contentViewController as? MPRViewerViewController {
            return viewer
        }
        return nil
    }

    @objc private func setRenderMode(_ sender: NSMenuItem) {
        guard let mode = VolumeRenderMode(rawValue: sender.tag) else { return }
        activeMPRViewer?.setRenderMode(mode)
    }

    @objc private func setVRPreset(_ sender: NSMenuItem) {
        guard sender.tag < VRPreset.allCases.count else { return }
        let preset = VRPreset.allCases[sender.tag]
        activeMPRViewer?.setVRPreset(preset)
    }

    // MARK: - Network Menu Actions

    @objc private func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.show()
    }

    @objc private func showQueryDialog(_ sender: Any?) {
        let queryVC = DicomQueryViewController()

        // Create a window for the query dialog
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Query/Retrieve PACS"
        window.contentViewController = queryVC
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func exportImages(_ sender: Any?) {
        guard let dbManager = databaseManager else { return }

        // Get current context from main window controller
        let currentInstance = mainWindowController?.currentInstance
        let currentSeriesRowID = mainWindowController?.currentSeriesRowID
        let currentStudyRowID = mainWindowController?.currentStudyRowID

        // Create export service
        let exportService = DicomExportService(bridge: bridge, database: dbManager)

        // Create export view controller
        let exportVC = ExportViewController(
            exportService: exportService,
            database: dbManager,
            currentInstance: currentInstance,
            currentSeriesRowID: currentSeriesRowID,
            currentStudyRowID: currentStudyRowID
        )

        // Create a window for the export dialog
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Export Images"
        window.contentViewController = exportVC
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func anonymizeImages(_ sender: Any?) {
        guard let dbManager = databaseManager else { return }

        // Get files to anonymize from current selection
        var selectedFiles: [String] = []

        if let seriesRowID = mainWindowController?.currentSeriesRowID {
            do {
                let instances = try dbManager.fetchInstances(forSeries: seriesRowID)
                selectedFiles = instances.map { $0.filePath }
            } catch {
                NSLog("[AppDelegate] Failed to fetch instances: %@", error.localizedDescription)
            }
        }

        // Create anonymization service
        let anonymizationService = DicomAnonymizationService(database: dbManager)

        // Create anonymization settings view controller
        let anonymizationVC = AnonymizationSettingsViewController(
            anonymizationService: anonymizationService,
            database: dbManager,
            selectedFiles: selectedFiles
        )

        // Create a window for the anonymization dialog
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Anonymize DICOM Files"
        window.contentViewController = anonymizationVC
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Layout":
            updateLayoutMenu(menu)
        case "Render Mode":
            updateRenderModeMenu(menu)
        case "VR Preset":
            updateVRPresetMenu(menu)
        default:
            break
        }
    }

    private func updateLayoutMenu(_ menu: NSMenu) {
        let currentLayout = mainWindowController?.currentLayout
        let isLinked = mainWindowController?.isLinked ?? false

        for item in menu.items {
            if let layout = item.representedObject as? HangingProtocol {
                item.state = (layout.id == currentLayout?.id) ? .on : .off
            } else if item.action == #selector(toggleLinking(_:)) {
                item.state = isLinked ? .on : .off
            }
        }
    }

    private func updateRenderModeMenu(_ menu: NSMenu) {
        let currentMode = activeMPRViewer?.renderMode ?? .mip

        for item in menu.items {
            item.state = (item.tag == currentMode.rawValue) ? .on : .off
        }

        // Enable items only when an MPR window is active
        let hasMPR = activeMPRViewer != nil
        for item in menu.items {
            item.isEnabled = hasMPR
        }
    }

    private func updateVRPresetMenu(_ menu: NSMenu) {
        let currentPreset = activeMPRViewer?.vrPreset ?? .bone
        let currentPresetIndex = VRPreset.allCases.firstIndex(of: currentPreset) ?? 0

        for item in menu.items {
            item.state = (item.tag == currentPresetIndex) ? .on : .off
        }

        // Enable items only when VR mode is active
        let isVRMode = activeMPRViewer?.renderMode == .vr
        for item in menu.items {
            item.isEnabled = isVRMode
        }
    }
}

extension Notification.Name {
    static let dicomOpenInMPR = Notification.Name("dicomOpenInMPR")
}

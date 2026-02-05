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
    private let bridge = DicomBridgeWrapper()

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
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

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
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing DICOM files"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.indexFolder(at: url.path)
            }
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
}

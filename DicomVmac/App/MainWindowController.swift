//
//  MainWindowController.swift
//  DicomVmac
//
//  Creates and manages the main application window with a split view:
//  sidebar (study browser) on the left, viewer grid on the right.
//

import AppKit

final class MainWindowController: NSWindowController {

    private var sidebarVC: SidebarViewController!
    private var gridVC: ViewerGridViewController!
    nonisolated(unsafe) private var seriesObserver: Any?

    // Current selection context for export
    var currentInstance: Instance?
    var currentSeriesRowID: Int64?
    var currentStudyRowID: Int64?

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable
        ]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "DicomVmac"
        window.setFrameAutosaveName("MainWindow")
        window.center()
        window.minSize = NSSize(width: 800, height: 600)

        super.init(window: window)

        setupSplitView()
        setupSeriesSelectionObserver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer = seriesObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Split View Layout

    private func setupSplitView() {
        let splitView = NSSplitViewController()

        sidebarVC = SidebarViewController()
        gridVC = ViewerGridViewController()

        // Sidebar (study browser)
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarVC
        )
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        splitView.addSplitViewItem(sidebarItem)

        // Main content (viewer grid)
        let viewerItem = NSSplitViewItem(
            contentListWithViewController: gridVC
        )
        viewerItem.minimumThickness = 400
        splitView.addSplitViewItem(viewerItem)

        window?.contentViewController = splitView
    }

    // MARK: - Series Selection

    private func setupSeriesSelectionObserver() {
        seriesObserver = NotificationCenter.default.addObserver(
            forName: .dicomSeriesDidSelect, object: nil, queue: .main
        ) { [weak self] notification in
            guard let series = notification.userInfo?["series"] as? Series else { return }
            self?.gridVC.loadSeries(series)

            // Track current selection context for export
            self?.currentSeriesRowID = series.id
            self?.currentStudyRowID = series.studyRowID

            // Try to get the first instance from the series
            if let db = AppDelegate.shared.databaseManager,
               let seriesID = series.id {
                do {
                    let instances = try db.fetchInstances(forSeries: seriesID)
                    self?.currentInstance = instances.first
                } catch {
                    NSLog("[MainWindowController] Failed to fetch instances: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Annotation Tool Actions

    func setAnnotationTool(_ tool: AnnotationTool) {
        gridVC.setAnnotationTool(tool)
    }

    func deleteSelectedAnnotation() {
        gridVC.deleteSelectedAnnotation()
    }

    // MARK: - Layout Actions

    /// Set the viewer grid layout.
    func setLayout(_ layout: HangingProtocol) {
        gridVC.setLayout(layout)
    }

    /// Get the current layout.
    var currentLayout: HangingProtocol {
        gridVC.currentLayout
    }

    /// Toggle viewer linking.
    func toggleLinking() {
        gridVC.isLinked.toggle()
    }

    /// Check if viewers are linked.
    var isLinked: Bool {
        gridVC.isLinked
    }
}

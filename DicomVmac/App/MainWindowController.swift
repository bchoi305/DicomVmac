//
//  MainWindowController.swift
//  DicomVmac
//
//  Creates and manages the main application window with a split view:
//  sidebar (study browser) on the left, Metal viewer canvas on the right.
//

import AppKit

final class MainWindowController: NSWindowController {

    private var sidebarVC: SidebarViewController!
    private var viewerVC: ViewerViewController!
    nonisolated(unsafe) private var seriesObserver: Any?

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
        viewerVC = ViewerViewController()

        // Sidebar (study browser)
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarVC
        )
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        splitView.addSplitViewItem(sidebarItem)

        // Main content (Metal viewer)
        let viewerItem = NSSplitViewItem(
            contentListWithViewController: viewerVC
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
            self?.viewerVC.loadSeries(series)
        }
    }

    // MARK: - Annotation Tool Actions

    func setAnnotationTool(_ tool: AnnotationTool) {
        viewerVC.setAnnotationTool(tool)
    }

    func deleteSelectedAnnotation() {
        viewerVC.deleteSelectedAnnotation()
    }
}

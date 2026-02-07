//
//  ViewerGridViewController.swift
//  DicomVmac
//
//  Container that manages multiple ViewerViewControllers in a grid layout.
//  Supports Hanging Protocols for multi-viewer comparison.
//

import AppKit

final class ViewerGridViewController: NSViewController {

    private var viewers: [ViewerViewController] = []
    private var viewerContainers: [NSView] = []
    private var activeViewerIndex: Int = 0
    private(set) var currentLayout: HangingProtocol = .default
    var linkOptions: ViewerLinkOptions = []

    private var mainStack: NSStackView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.distribution = .fillEqually
        mainStack.spacing = 2
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Start with default 1×1 layout
        setLayout(.default)
    }

    // MARK: - Layout Management

    /// Set the grid layout.
    func setLayout(_ layout: HangingProtocol) {
        currentLayout = layout

        // Preserve content from existing viewers
        let existingSeries = viewers.prefix(layout.cellCount).compactMap { $0.currentSeries }

        // Clear existing layout
        clearLayout()

        // Create new grid
        for row in 0..<layout.rows {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = 2

            for col in 0..<layout.cols {
                let cellIndex = row * layout.cols + col
                let (container, viewer) = createViewerCell(index: cellIndex)
                rowStack.addArrangedSubview(container)
                viewers.append(viewer)
                viewerContainers.append(container)

                // Restore content if available
                if cellIndex < existingSeries.count {
                    viewer.loadSeries(existingSeries[cellIndex])
                }
            }

            mainStack.addArrangedSubview(rowStack)
        }

        // Set active viewer
        activeViewerIndex = min(activeViewerIndex, viewers.count - 1)
        updateActiveHighlight()
    }

    private func createViewerCell(index: Int) -> (NSView, ViewerViewController) {
        // Container with border
        let container = NSView()
        container.wantsLayer = true
        container.layer?.borderWidth = 2
        container.layer?.borderColor = NSColor.darkGray.cgColor

        // Create viewer
        let viewer = ViewerViewController()
        viewer.delegate = self
        addChild(viewer)
        viewer.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(viewer.view)

        NSLayoutConstraint.activate([
            viewer.view.topAnchor.constraint(equalTo: container.topAnchor),
            viewer.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            viewer.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            viewer.view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        // Click gesture to make active
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(cellClicked(_:)))
        container.addGestureRecognizer(clickGesture)

        return (container, viewer)
    }

    private func clearLayout() {
        // Remove all children
        for viewer in viewers {
            viewer.removeFromParent()
        }
        viewers.removeAll()
        viewerContainers.removeAll()

        // Clear stack
        for arrangedSubview in mainStack.arrangedSubviews {
            mainStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
    }

    // MARK: - Active Viewer

    /// The currently active viewer (receives series selection).
    var activeViewer: ViewerViewController {
        viewers[activeViewerIndex]
    }

    /// Make a specific viewer active.
    func setActiveViewer(at index: Int) {
        guard index >= 0 && index < viewers.count else { return }
        activeViewerIndex = index
        updateActiveHighlight()
    }

    private func updateActiveHighlight() {
        for (index, container) in viewerContainers.enumerated() {
            if index == activeViewerIndex {
                container.layer?.borderColor = NSColor.systemBlue.cgColor
                container.layer?.borderWidth = 3
            } else {
                container.layer?.borderColor = NSColor.darkGray.cgColor
                container.layer?.borderWidth = 2
            }
        }
    }

    @objc private func cellClicked(_ gesture: NSClickGestureRecognizer) {
        guard let container = gesture.view,
              let index = viewerContainers.firstIndex(of: container) else { return }
        setActiveViewer(at: index)
    }

    // MARK: - Series Loading

    /// Load a series into the active viewer.
    func loadSeries(_ series: Series) {
        activeViewer.loadSeries(series)
    }

    // MARK: - Annotation Forwarding

    /// Set the annotation tool on the active viewer.
    func setAnnotationTool(_ tool: AnnotationTool) {
        activeViewer.setAnnotationTool(tool)
    }

    /// Delete the selected annotation in the active viewer.
    func deleteSelectedAnnotation() {
        activeViewer.deleteSelectedAnnotation()
    }

    // MARK: - Linking

    /// Toggle viewer linking.
    var isLinked: Bool {
        get { linkOptions != .none }
        set { linkOptions = newValue ? .all : .none }
    }
}

// MARK: - ViewerViewControllerDelegate

extension ViewerGridViewController: ViewerViewControllerDelegate {

    func viewer(_ viewer: ViewerViewController, didScrollToSlice index: Int, totalSlices: Int) {
        guard linkOptions.contains(.scroll) else { return }

        // Sync scroll to other viewers (proportionally if different slice counts)
        let proportion = Double(index) / max(Double(totalSlices - 1), 1.0)

        for other in viewers where other !== viewer {
            let otherTotal = other.sliceCount
            if otherTotal > 0 {
                let targetIndex = Int(proportion * Double(otherTotal - 1))
                other.scrollToSlice(targetIndex, notify: false)
            }
        }
    }

    func viewer(_ viewer: ViewerViewController, didChangeWindowLevel center: Float, width: Float) {
        guard linkOptions.contains(.windowLevel) else { return }

        for other in viewers where other !== viewer {
            other.setWindowLevel(center: center, width: width, notify: false)
        }
    }

    func viewer(_ viewer: ViewerViewController, didChangeZoom scale: Float) {
        guard linkOptions.contains(.zoom) else { return }

        for other in viewers where other !== viewer {
            other.setZoom(scale: scale, notify: false)
        }
    }
}

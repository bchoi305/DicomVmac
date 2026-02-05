//
//  SidebarViewController.swift
//  DicomVmac
//
//  Study browser sidebar with 3-level Patient > Study > Series hierarchy.
//

import AppKit

/// Node types for the outline view hierarchy.
enum SidebarNode {
    case patient(Patient)
    case study(Study)
    case series(Series)

    var displayTitle: String {
        switch self {
        case .patient(let p):
            return p.patientName
        case .study(let s):
            let date = s.studyDate ?? ""
            let mod = s.modality ?? ""
            let desc = s.studyDescription ?? "Study"
            let parts = [date, mod, desc].filter { !$0.isEmpty }
            return parts.joined(separator: " — ")
        case .series(let s):
            let num = s.seriesNumber.map { "S\($0)" } ?? ""
            let desc = s.seriesDescription ?? s.modality ?? "Series"
            let count = "(\(s.instanceCount))"
            let parts = [num, desc, count].filter { !$0.isEmpty }
            return parts.joined(separator: " ")
        }
    }
}

/// Wrapper class for SidebarNode so NSOutlineView can use it as an object.
final class SidebarItem: NSObject {
    let node: SidebarNode
    var children: [SidebarItem]?

    init(node: SidebarNode, children: [SidebarItem]? = nil) {
        self.node = node
    }
}

final class SidebarViewController: NSViewController {

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var rootItems: [SidebarItem] = []
    private var emptyLabel: NSTextField?
    nonisolated(unsafe) private var dbObserver: Any?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Studies"
        setupOutlineView()
        setupEmptyLabel()
        setupDragDrop()

        dbObserver = NotificationCenter.default.addObserver(
            forName: .dicomDatabaseDidUpdate, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }

        reloadData()
    }

    deinit {
        if let observer = dbObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupOutlineView() {
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = 22
        outlineView.style = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupEmptyLabel() {
        let label = NSTextField(labelWithString: "Study Browser\n\nDrag a DICOM folder here\nor use File > Open Folder")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -20)
        ])
        emptyLabel = label
    }

    private func setupDragDrop() {
        view.registerForDraggedTypes([.fileURL])
    }

    // MARK: - Data Loading

    func reloadData() {
        guard let dbManager = AppDelegate.shared.databaseManager else { return }

        do {
            let patients = try dbManager.fetchPatients()
            rootItems = try patients.map { patient in
                let studies = try dbManager.fetchStudies(forPatient: patient.id!)
                let studyItems = try studies.map { study in
                    let seriesList = try dbManager.fetchSeries(forStudy: study.id!)
                    let seriesItems = seriesList.map { series in
                        SidebarItem(node: .series(series))
                    }
                    let studyItem = SidebarItem(node: .study(study))
                    studyItem.children = seriesItems
                    return studyItem
                }
                let patientItem = SidebarItem(node: .patient(patient))
                patientItem.children = studyItems
                return patientItem
            }
        } catch {
            NSLog("[Sidebar] Failed to load hierarchy: %@", error.localizedDescription)
            rootItems = []
        }

        outlineView.reloadData()
        emptyLabel?.isHidden = !rootItems.isEmpty
        scrollView.isHidden = rootItems.isEmpty

        // Auto-expand all patients and studies
        for item in rootItems {
            outlineView.expandItem(item)
            if let children = item.children {
                for child in children {
                    outlineView.expandItem(child)
                }
            }
        }
    }

}

// MARK: - NSDraggingDestination

extension SidebarViewController {

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        return .copy
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return false }

        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                AppDelegate.shared.indexFolder(at: url.path)
            }
        }
        return true
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootItems.count }
        guard let sidebarItem = item as? SidebarItem else { return 0 }
        return sidebarItem.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView,
                     child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootItems[index] }
        let sidebarItem = item as! SidebarItem
        return sidebarItem.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView,
                     isItemExpandable item: Any) -> Bool {
        guard let sidebarItem = item as? SidebarItem else { return false }
        return sidebarItem.children != nil && !sidebarItem.children!.isEmpty
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cellView: NSTableCellView
        if let reused = outlineView.makeView(
            withIdentifier: identifier, owner: self) as? NSTableCellView {
            cellView = reused
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cellView.addSubview(textField)
            cellView.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
            ])
        }

        cellView.textField?.stringValue = sidebarItem.node.displayTitle

        switch sidebarItem.node {
        case .patient:
            cellView.textField?.font = .boldSystemFont(ofSize: 13)
        case .study:
            cellView.textField?.font = .systemFont(ofSize: 12)
        case .series:
            cellView.textField?.font = .systemFont(ofSize: 11)
        }

        return cellView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let sidebarItem = outlineView.item(atRow: row) as? SidebarItem else { return }

        if case .series(let series) = sidebarItem.node {
            NotificationCenter.default.post(
                name: .dicomSeriesDidSelect,
                object: nil,
                userInfo: ["series": series])
        }
    }
}

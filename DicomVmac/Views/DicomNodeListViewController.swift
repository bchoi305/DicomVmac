//
//  DicomNodeListViewController.swift
//  DicomVmac
//
//  View controller for managing PACS nodes (list view with add/edit/delete/test).
//

import Cocoa

/// View controller for displaying and managing PACS nodes
final class DicomNodeListViewController: NSViewController {

    // MARK: - UI Components

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let editButton = NSButton()
    private let deleteButton = NSButton()
    private let testButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField()

    // MARK: - Data

    private var nodes: [DicomNode] = []
    private var database: DatabaseManager?
    private var networkService: DicomNetworkService?
    private var bridge: DicomBridgeWrapper?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDependencies()
        loadNodes()
    }

    // MARK: - Setup

    private func setupDependencies() {
        // Get dependencies from AppDelegate
        if let appDelegate = NSApp.delegate as? AppDelegate {
            self.database = appDelegate.databaseManager
            self.bridge = appDelegate.bridge
            if let db = database, let br = bridge {
                self.networkService = DicomNetworkService(
                    bridge: br,
                    database: db
                )
            }
        }
    }

    private func setupUI() {
        // Configure table view
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(editNode)
        tableView.delegate = self
        tableView.dataSource = self

        // Add columns
        let aeTitleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("aeTitle"))
        aeTitleColumn.title = "AE Title"
        aeTitleColumn.width = 120
        tableView.addTableColumn(aeTitleColumn)

        let hostnameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hostname"))
        hostnameColumn.title = "Hostname"
        hostnameColumn.width = 200
        tableView.addTableColumn(hostnameColumn)

        let portColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("port"))
        portColumn.title = "Port"
        portColumn.width = 60
        tableView.addTableColumn(portColumn)

        let descColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("description"))
        descColumn.title = "Description"
        descColumn.width = 200
        tableView.addTableColumn(descColumn)

        let activeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("active"))
        activeColumn.title = "Active"
        activeColumn.width = 60
        tableView.addTableColumn(activeColumn)

        // Configure scroll view
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Configure buttons
        addButton.title = "Add"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addNode)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        editButton.title = "Edit"
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editNode)
        editButton.isEnabled = false
        editButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.title = "Delete"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteNode)
        deleteButton.isEnabled = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        testButton.title = "Test Connection"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.isEnabled = false
        testButton.translatesAutoresizingMaskIntoConstraints = false

        // Configure progress indicator
        progressIndicator.style = .spinning
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        // Configure status label
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.backgroundColor = .clear
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Add subviews
        view.addSubview(scrollView)
        view.addSubview(addButton)
        view.addSubview(editButton)
        view.addSubview(deleteButton)
        view.addSubview(testButton)
        view.addSubview(progressIndicator)
        view.addSubview(statusLabel)

        // Layout constraints
        NSLayoutConstraint.activate([
            // Scroll view (top)
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -20),

            // Buttons (bottom left)
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            addButton.widthAnchor.constraint(equalToConstant: 80),

            editButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            editButton.bottomAnchor.constraint(equalTo: addButton.bottomAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 80),

            deleteButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 8),
            deleteButton.bottomAnchor.constraint(equalTo: addButton.bottomAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 80),

            // Test button (bottom right)
            testButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            testButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            testButton.widthAnchor.constraint(equalToConstant: 140),

            // Progress indicator
            progressIndicator.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -12),

            // Status label
            statusLabel.centerYAnchor.constraint(equalTo: testButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -8)
        ])
    }

    // MARK: - Data Loading

    private func loadNodes() {
        guard let database = database else { return }

        do {
            nodes = try database.fetchDicomNodes()
            tableView.reloadData()
            updateButtonStates()
        } catch {
            showError("Failed to load PACS nodes: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    @objc private func addNode() {
        let editor = DicomNodeEditorViewController(node: nil, database: database)
        editor.onSave = { [weak self] in
            self?.loadNodes()
        }

        presentAsSheet(editor)
    }

    @objc private func editNode() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < nodes.count else { return }

        let node = nodes[selectedRow]
        let editor = DicomNodeEditorViewController(node: node, database: database)
        editor.onSave = { [weak self] in
            self?.loadNodes()
        }

        presentAsSheet(editor)
    }

    @objc private func deleteNode() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < nodes.count else { return }

        let node = nodes[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Delete PACS Node"
        alert.informativeText = "Are you sure you want to delete '\(node.aeTitle)@\(node.hostname):\(node.port)'?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(node: node)
        }
    }

    private func performDelete(node: DicomNode) {
        guard let database = database, let id = node.id else { return }

        do {
            try database.deleteDicomNode(id: id)
            loadNodes()
        } catch {
            showError("Failed to delete PACS node: \(error.localizedDescription)")
        }
    }

    @objc private func testConnection() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < nodes.count else { return }

        let node = nodes[selectedRow]

        guard let networkService = networkService else {
            showError("Network service not available")
            return
        }

        // Show progress
        showProgress("Testing connection to \(node.aeTitle)...")

        Task { @MainActor in
            do {
                try await networkService.verifyConnection(to: node)
                hideProgress()
                showSuccess("Connection successful!")
            } catch {
                hideProgress()
                if let netError = error as? DicomNetworkError {
                    showError(netError.localizedDescription)
                } else {
                    showError("Connection test failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - UI Helpers

    private func updateButtonStates() {
        let hasSelection = tableView.selectedRow >= 0
        editButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        testButton.isEnabled = hasSelection
    }

    private func showProgress(_ message: String) {
        statusLabel.stringValue = message
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        addButton.isEnabled = false
        editButton.isEnabled = false
        deleteButton.isEnabled = false
        testButton.isEnabled = false
    }

    private func hideProgress() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.stringValue = ""
        addButton.isEnabled = true
        updateButtonStates()
    }

    private func showSuccess(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: view.window!, completionHandler: nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: view.window!, completionHandler: nil)
    }
}

// MARK: - NSTableViewDataSource

extension DicomNodeListViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        return nodes.count
    }
}

// MARK: - NSTableViewDelegate

extension DicomNodeListViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < nodes.count else { return nil }

        let node = nodes[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")

        let cellView = NSTableCellView()
        let textField = NSTextField()
        textField.isEditable = false
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.translatesAutoresizingMaskIntoConstraints = false

        cellView.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        switch identifier.rawValue {
        case "aeTitle":
            textField.stringValue = node.aeTitle
        case "hostname":
            textField.stringValue = node.hostname
        case "port":
            textField.stringValue = "\(node.port)"
        case "description":
            textField.stringValue = node.description ?? ""
        case "active":
            textField.stringValue = node.isActive ? "Yes" : "No"
        default:
            break
        }

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }
}

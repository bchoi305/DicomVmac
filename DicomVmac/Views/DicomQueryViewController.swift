//
//  DicomQueryViewController.swift
//  DicomVmac
//
//  View controller for querying PACS servers and retrieving studies.
//

import Cocoa

/// View controller for PACS query and retrieve operations
final class DicomQueryViewController: NSViewController {

    // MARK: - UI Components - Search Criteria

    private let nodePopup = NSPopUpButton()
    private let patientIDField = NSTextField()
    private let patientNameField = NSTextField()
    private let dateFromPicker = NSDatePicker()
    private let dateToPicker = NSDatePicker()
    private let modalityField = NSTextField()
    private let accessionField = NSTextField()
    private let searchButton = NSButton()

    // MARK: - UI Components - Results

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let retrieveButton = NSButton()
    private let closeButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField()

    // MARK: - Data

    private var nodes: [DicomNode] = []
    private var results: [DicomTagData] = []
    private var database: DatabaseManager?
    private var networkService: DicomNetworkService?
    private var bridge: DicomBridgeWrapper?

    // MARK: - Initialization

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
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
        // Search criteria section
        let criteriaBox = createCriteriaSection()
        criteriaBox.translatesAutoresizingMaskIntoConstraints = false

        // Results section
        setupResultsSection()
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom buttons
        setupBottomButtons()

        // Add subviews
        view.addSubview(criteriaBox)
        view.addSubview(scrollView)
        view.addSubview(retrieveButton)
        view.addSubview(closeButton)
        view.addSubview(progressIndicator)
        view.addSubview(statusLabel)

        // Layout
        NSLayoutConstraint.activate([
            // Criteria box (top)
            criteriaBox.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            criteriaBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            criteriaBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Results table (middle)
            scrollView.topAnchor.constraint(equalTo: criteriaBox.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -20),

            // Buttons (bottom)
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 80),

            retrieveButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
            retrieveButton.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor),
            retrieveButton.widthAnchor.constraint(equalToConstant: 100),

            // Progress indicator
            progressIndicator.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: retrieveButton.leadingAnchor, constant: -12),

            // Status label
            statusLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -8)
        ])
    }

    private func createCriteriaSection() -> NSBox {
        let box = NSBox()
        box.title = "Search Criteria"
        box.titlePosition = .atTop

        let contentView = NSView()
        box.contentView = contentView

        // Labels
        let nodeLabel = createLabel("PACS Node:")
        let patientIDLabel = createLabel("Patient ID:")
        let patientNameLabel = createLabel("Patient Name:")
        let dateFromLabel = createLabel("Study Date From:")
        let dateToLabel = createLabel("To:")
        let modalityLabel = createLabel("Modality:")
        let accessionLabel = createLabel("Accession Number:")

        // Node popup
        nodePopup.translatesAutoresizingMaskIntoConstraints = false

        // Text fields
        patientIDField.placeholderString = "e.g., 12345 or *Smith*"
        patientIDField.translatesAutoresizingMaskIntoConstraints = false

        patientNameField.placeholderString = "e.g., Smith^John or Smith*"
        patientNameField.translatesAutoresizingMaskIntoConstraints = false

        modalityField.placeholderString = "e.g., CT, MR, CR"
        modalityField.translatesAutoresizingMaskIntoConstraints = false

        accessionField.placeholderString = "e.g., ACC123456"
        accessionField.translatesAutoresizingMaskIntoConstraints = false

        // Date pickers
        dateFromPicker.datePickerStyle = .textField
        dateFromPicker.datePickerElements = .yearMonthDay
        dateFromPicker.translatesAutoresizingMaskIntoConstraints = false

        dateToPicker.datePickerStyle = .textField
        dateToPicker.datePickerElements = .yearMonthDay
        dateToPicker.dateValue = Date()
        dateToPicker.translatesAutoresizingMaskIntoConstraints = false

        // Search button
        searchButton.title = "Search"
        searchButton.bezelStyle = .rounded
        searchButton.keyEquivalent = "\r"
        searchButton.target = self
        searchButton.action = #selector(performQuery)
        searchButton.translatesAutoresizingMaskIntoConstraints = false

        // Add subviews
        contentView.addSubview(nodeLabel)
        contentView.addSubview(nodePopup)
        contentView.addSubview(patientIDLabel)
        contentView.addSubview(patientIDField)
        contentView.addSubview(patientNameLabel)
        contentView.addSubview(patientNameField)
        contentView.addSubview(dateFromLabel)
        contentView.addSubview(dateFromPicker)
        contentView.addSubview(dateToLabel)
        contentView.addSubview(dateToPicker)
        contentView.addSubview(modalityLabel)
        contentView.addSubview(modalityField)
        contentView.addSubview(accessionLabel)
        contentView.addSubview(accessionField)
        contentView.addSubview(searchButton)

        // Layout
        NSLayoutConstraint.activate([
            // PACS Node
            nodeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            nodeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nodeLabel.widthAnchor.constraint(equalToConstant: 130),

            nodePopup.centerYAnchor.constraint(equalTo: nodeLabel.centerYAnchor),
            nodePopup.leadingAnchor.constraint(equalTo: nodeLabel.trailingAnchor, constant: 8),
            nodePopup.widthAnchor.constraint(equalToConstant: 300),

            // Patient ID
            patientIDLabel.topAnchor.constraint(equalTo: nodeLabel.bottomAnchor, constant: 16),
            patientIDLabel.leadingAnchor.constraint(equalTo: nodeLabel.leadingAnchor),
            patientIDLabel.widthAnchor.constraint(equalToConstant: 130),

            patientIDField.centerYAnchor.constraint(equalTo: patientIDLabel.centerYAnchor),
            patientIDField.leadingAnchor.constraint(equalTo: nodePopup.leadingAnchor),
            patientIDField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // Patient Name
            patientNameLabel.topAnchor.constraint(equalTo: patientIDLabel.bottomAnchor, constant: 12),
            patientNameLabel.leadingAnchor.constraint(equalTo: nodeLabel.leadingAnchor),
            patientNameLabel.widthAnchor.constraint(equalToConstant: 130),

            patientNameField.centerYAnchor.constraint(equalTo: patientNameLabel.centerYAnchor),
            patientNameField.leadingAnchor.constraint(equalTo: nodePopup.leadingAnchor),
            patientNameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // Study Date
            dateFromLabel.topAnchor.constraint(equalTo: patientNameLabel.bottomAnchor, constant: 12),
            dateFromLabel.leadingAnchor.constraint(equalTo: nodeLabel.leadingAnchor),
            dateFromLabel.widthAnchor.constraint(equalToConstant: 130),

            dateFromPicker.centerYAnchor.constraint(equalTo: dateFromLabel.centerYAnchor),
            dateFromPicker.leadingAnchor.constraint(equalTo: nodePopup.leadingAnchor),
            dateFromPicker.widthAnchor.constraint(equalToConstant: 150),

            dateToLabel.centerYAnchor.constraint(equalTo: dateFromLabel.centerYAnchor),
            dateToLabel.leadingAnchor.constraint(equalTo: dateFromPicker.trailingAnchor, constant: 8),
            dateToLabel.widthAnchor.constraint(equalToConstant: 30),

            dateToPicker.centerYAnchor.constraint(equalTo: dateFromLabel.centerYAnchor),
            dateToPicker.leadingAnchor.constraint(equalTo: dateToLabel.trailingAnchor, constant: 8),
            dateToPicker.widthAnchor.constraint(equalToConstant: 150),

            // Modality
            modalityLabel.topAnchor.constraint(equalTo: dateFromLabel.bottomAnchor, constant: 12),
            modalityLabel.leadingAnchor.constraint(equalTo: nodeLabel.leadingAnchor),
            modalityLabel.widthAnchor.constraint(equalToConstant: 130),

            modalityField.centerYAnchor.constraint(equalTo: modalityLabel.centerYAnchor),
            modalityField.leadingAnchor.constraint(equalTo: nodePopup.leadingAnchor),
            modalityField.widthAnchor.constraint(equalToConstant: 200),

            // Accession Number
            accessionLabel.topAnchor.constraint(equalTo: modalityLabel.bottomAnchor, constant: 12),
            accessionLabel.leadingAnchor.constraint(equalTo: nodeLabel.leadingAnchor),
            accessionLabel.widthAnchor.constraint(equalToConstant: 130),

            accessionField.centerYAnchor.constraint(equalTo: accessionLabel.centerYAnchor),
            accessionField.leadingAnchor.constraint(equalTo: nodePopup.leadingAnchor),
            accessionField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // Search button
            searchButton.topAnchor.constraint(equalTo: accessionLabel.bottomAnchor, constant: 20),
            searchButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            searchButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            searchButton.widthAnchor.constraint(equalToConstant: 100)
        ])

        return box
    }

    private func setupResultsSection() {
        // Configure table view
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(retrieveStudy)
        tableView.delegate = self
        tableView.dataSource = self

        // Add columns
        addColumn(id: "patientID", title: "Patient ID", width: 120)
        addColumn(id: "patientName", title: "Patient Name", width: 200)
        addColumn(id: "studyDate", title: "Study Date", width: 100)
        addColumn(id: "modality", title: "Modality", width: 80)
        addColumn(id: "description", title: "Description", width: 250)
        addColumn(id: "accession", title: "Accession #", width: 120)

        // Configure scroll view
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
    }

    private func addColumn(id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    private func setupBottomButtons() {
        retrieveButton.title = "Retrieve"
        retrieveButton.bezelStyle = .rounded
        retrieveButton.target = self
        retrieveButton.action = #selector(retrieveStudy)
        retrieveButton.isEnabled = false
        retrieveButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = "Close"
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"  // Escape key
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.backgroundColor = .clear
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func createLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Data Loading

    private func loadNodes() {
        guard let database = database else { return }

        do {
            nodes = try database.fetchDicomNodes().filter { $0.isActive && $0.isQueryRetrieve }

            nodePopup.removeAllItems()
            for node in nodes {
                nodePopup.addItem(withTitle: "\(node.aeTitle)@\(node.hostname):\(node.port)")
            }

            if nodes.isEmpty {
                showError("No active PACS nodes configured. Please add a PACS node in Preferences.")
                searchButton.isEnabled = false
            }
        } catch {
            showError("Failed to load PACS nodes: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    @objc private func performQuery() {
        guard !nodes.isEmpty else {
            showError("No PACS nodes available")
            return
        }

        let selectedIndex = nodePopup.indexOfSelectedItem
        guard selectedIndex >= 0, selectedIndex < nodes.count else {
            showError("Please select a PACS node")
            return
        }

        let node = nodes[selectedIndex]

        // Build search criteria
        let criteria = buildCriteria()

        guard criteria.hasAnyCriteria else {
            showError("Please specify at least one search criterion")
            return
        }

        guard let networkService = networkService else {
            showError("Network service not available")
            return
        }

        // Clear previous results
        results.removeAll()
        tableView.reloadData()
        updateButtonStates()

        // Show progress
        showProgress("Querying \(node.aeTitle)...")

        Task { @MainActor in
            do {
                try await networkService.queryStudies(
                    from: node,
                    criteria: criteria,
                    onResult: { [weak self] tagData in
                        Task { @MainActor in
                            self?.results.append(tagData)
                            self?.tableView.reloadData()
                        }
                    }
                )

                hideProgress()
                statusLabel.stringValue = "\(results.count) studies found"
                updateButtonStates()

            } catch {
                hideProgress()
                if let netError = error as? DicomNetworkError {
                    showError(netError.localizedDescription)
                } else {
                    showError("Query failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func retrieveStudy() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < results.count else { return }

        let study = results[selectedRow]
        let selectedIndex = nodePopup.indexOfSelectedItem
        guard selectedIndex >= 0, selectedIndex < nodes.count else { return }

        let node = nodes[selectedIndex]

        guard let networkService = networkService else {
            showError("Network service not available")
            return
        }

        // Show progress
        showProgress("Retrieving study...")

        Task { @MainActor in
            do {
                _ = try await networkService.retrieveStudy(
                    from: node,
                    studyInstanceUID: study.studyInstanceUID,
                    onProgress: { [weak self] completed, remaining, failed in
                        Task { @MainActor in
                            self?.statusLabel.stringValue = "Retrieving: \(completed) completed, \(remaining) remaining, \(failed) failed"
                        }
                    }
                )

                hideProgress()
                showSuccess("Study retrieved successfully")

                // Notify that database was updated
                NotificationCenter.default.post(name: .dicomDatabaseDidUpdate, object: nil)

            } catch {
                hideProgress()
                if let netError = error as? DicomNetworkError {
                    showError(netError.localizedDescription)
                } else {
                    showError("Retrieve failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func close() {
        dismiss(nil)
    }

    // MARK: - Helpers

    private func buildCriteria() -> DicomQueryCriteria {
        var criteria = DicomQueryCriteria()

        let patientID = patientIDField.stringValue.trimmingCharacters(in: .whitespaces)
        if !patientID.isEmpty {
            criteria.patientID = patientID
        }

        let patientName = patientNameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !patientName.isEmpty {
            criteria.patientName = patientName
        }

        let modality = modalityField.stringValue.trimmingCharacters(in: .whitespaces)
        if !modality.isEmpty {
            criteria.modality = modality
        }

        let accession = accessionField.stringValue.trimmingCharacters(in: .whitespaces)
        if !accession.isEmpty {
            criteria.accessionNumber = accession
        }

        // Date range (only if from date is set)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"

        let fromString = dateFormatter.string(from: dateFromPicker.dateValue)
        let toString = dateFormatter.string(from: dateToPicker.dateValue)

        if !fromString.isEmpty {
            criteria.studyDate = DicomQueryCriteria.DateRange(from: fromString, to: toString)
        }

        return criteria
    }

    private func updateButtonStates() {
        let hasSelection = tableView.selectedRow >= 0
        retrieveButton.isEnabled = hasSelection
    }

    private func showProgress(_ message: String) {
        statusLabel.stringValue = message
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        searchButton.isEnabled = false
        retrieveButton.isEnabled = false
    }

    private func hideProgress() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        searchButton.isEnabled = true
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

extension DicomQueryViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        return results.count
    }
}

// MARK: - NSTableViewDelegate

extension DicomQueryViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count else { return nil }

        let study = results[row]
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
        case "patientID":
            textField.stringValue = study.patientID
        case "patientName":
            textField.stringValue = study.patientName
        case "studyDate":
            textField.stringValue = formatStudyDate(study.studyDate)
        case "modality":
            textField.stringValue = study.studyModality
        case "description":
            textField.stringValue = study.studyDescription
        case "accession":
            textField.stringValue = study.accessionNumber
        default:
            break
        }

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    private func formatStudyDate(_ dateString: String) -> String {
        guard dateString.count == 8 else { return dateString }

        let year = dateString.prefix(4)
        let month = dateString.dropFirst(4).prefix(2)
        let day = dateString.dropFirst(6).prefix(2)

        return "\(year)-\(month)-\(day)"
    }
}

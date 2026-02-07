//
//  DicomNodeEditorViewController.swift
//  DicomVmac
//
//  View controller for adding or editing a PACS node.
//

import Cocoa

/// View controller for editing PACS node configuration
final class DicomNodeEditorViewController: NSViewController {

    // MARK: - UI Components

    private let aeTitleField = NSTextField()
    private let hostnameField = NSTextField()
    private let portField = NSTextField()
    private let descriptionField = NSTextField()
    private let queryRetrieveCheckbox = NSButton(checkboxWithTitle: "Supports Query/Retrieve (C-FIND/C-MOVE)", target: nil, action: nil)
    private let storageCheckbox = NSButton(checkboxWithTitle: "Supports Storage (C-STORE)", target: nil, action: nil)
    private let activeCheckbox = NSButton(checkboxWithTitle: "Active", target: nil, action: nil)
    private let saveButton = NSButton()
    private let cancelButton = NSButton()

    // MARK: - Data

    private var node: DicomNode?
    private let database: DatabaseManager?
    var onSave: (() -> Void)?

    // MARK: - Initialization

    init(node: DicomNode?, database: DatabaseManager?) {
        self.node = node
        self.database = database
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 350)
        setupUI()
        populateFields()
    }

    // MARK: - Setup

    private func setupUI() {
        // Labels
        let aeTitleLabel = createLabel("AE Title:")
        let hostnameLabel = createLabel("Hostname:")
        let portLabel = createLabel("Port:")
        let descLabel = createLabel("Description:")
        let capabilitiesLabel = createLabel("Capabilities:")

        // Configure text fields
        aeTitleField.placeholderString = "PACS (max 16 chars)"
        aeTitleField.translatesAutoresizingMaskIntoConstraints = false

        hostnameField.placeholderString = "pacs.example.com or 192.168.1.100"
        hostnameField.translatesAutoresizingMaskIntoConstraints = false

        portField.placeholderString = "104"
        portField.translatesAutoresizingMaskIntoConstraints = false

        descriptionField.placeholderString = "Main Hospital PACS"
        descriptionField.translatesAutoresizingMaskIntoConstraints = false

        // Configure checkboxes
        queryRetrieveCheckbox.state = .on
        queryRetrieveCheckbox.translatesAutoresizingMaskIntoConstraints = false

        storageCheckbox.state = .on
        storageCheckbox.translatesAutoresizingMaskIntoConstraints = false

        activeCheckbox.state = .on
        activeCheckbox.translatesAutoresizingMaskIntoConstraints = false

        // Configure buttons
        saveButton.title = node == nil ? "Add" : "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"  // Escape key
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        // Add subviews
        view.addSubview(aeTitleLabel)
        view.addSubview(aeTitleField)
        view.addSubview(hostnameLabel)
        view.addSubview(hostnameField)
        view.addSubview(portLabel)
        view.addSubview(portField)
        view.addSubview(descLabel)
        view.addSubview(descriptionField)
        view.addSubview(capabilitiesLabel)
        view.addSubview(queryRetrieveCheckbox)
        view.addSubview(storageCheckbox)
        view.addSubview(activeCheckbox)
        view.addSubview(saveButton)
        view.addSubview(cancelButton)

        // Layout constraints
        NSLayoutConstraint.activate([
            // AE Title
            aeTitleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            aeTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            aeTitleLabel.widthAnchor.constraint(equalToConstant: 100),

            aeTitleField.centerYAnchor.constraint(equalTo: aeTitleLabel.centerYAnchor),
            aeTitleField.leadingAnchor.constraint(equalTo: aeTitleLabel.trailingAnchor, constant: 8),
            aeTitleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Hostname
            hostnameLabel.topAnchor.constraint(equalTo: aeTitleLabel.bottomAnchor, constant: 16),
            hostnameLabel.leadingAnchor.constraint(equalTo: aeTitleLabel.leadingAnchor),
            hostnameLabel.widthAnchor.constraint(equalToConstant: 100),

            hostnameField.centerYAnchor.constraint(equalTo: hostnameLabel.centerYAnchor),
            hostnameField.leadingAnchor.constraint(equalTo: aeTitleField.leadingAnchor),
            hostnameField.trailingAnchor.constraint(equalTo: aeTitleField.trailingAnchor),

            // Port
            portLabel.topAnchor.constraint(equalTo: hostnameLabel.bottomAnchor, constant: 16),
            portLabel.leadingAnchor.constraint(equalTo: aeTitleLabel.leadingAnchor),
            portLabel.widthAnchor.constraint(equalToConstant: 100),

            portField.centerYAnchor.constraint(equalTo: portLabel.centerYAnchor),
            portField.leadingAnchor.constraint(equalTo: aeTitleField.leadingAnchor),
            portField.widthAnchor.constraint(equalToConstant: 100),

            // Description
            descLabel.topAnchor.constraint(equalTo: portLabel.bottomAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: aeTitleLabel.leadingAnchor),
            descLabel.widthAnchor.constraint(equalToConstant: 100),

            descriptionField.centerYAnchor.constraint(equalTo: descLabel.centerYAnchor),
            descriptionField.leadingAnchor.constraint(equalTo: aeTitleField.leadingAnchor),
            descriptionField.trailingAnchor.constraint(equalTo: aeTitleField.trailingAnchor),

            // Capabilities
            capabilitiesLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 20),
            capabilitiesLabel.leadingAnchor.constraint(equalTo: aeTitleLabel.leadingAnchor),
            capabilitiesLabel.widthAnchor.constraint(equalToConstant: 100),

            queryRetrieveCheckbox.topAnchor.constraint(equalTo: capabilitiesLabel.bottomAnchor, constant: 8),
            queryRetrieveCheckbox.leadingAnchor.constraint(equalTo: aeTitleField.leadingAnchor),

            storageCheckbox.topAnchor.constraint(equalTo: queryRetrieveCheckbox.bottomAnchor, constant: 8),
            storageCheckbox.leadingAnchor.constraint(equalTo: aeTitleField.leadingAnchor),

            // Active
            activeCheckbox.topAnchor.constraint(equalTo: storageCheckbox.bottomAnchor, constant: 16),
            activeCheckbox.leadingAnchor.constraint(equalTo: aeTitleField.leadingAnchor),

            // Buttons
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),

            saveButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
            saveButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 80)
        ])
    }

    private func createLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func populateFields() {
        guard let node = node else { return }

        aeTitleField.stringValue = node.aeTitle
        hostnameField.stringValue = node.hostname
        portField.stringValue = "\(node.port)"
        descriptionField.stringValue = node.description ?? ""
        queryRetrieveCheckbox.state = node.isQueryRetrieve ? .on : .off
        storageCheckbox.state = node.isStorage ? .on : .off
        activeCheckbox.state = node.isActive ? .on : .off
    }

    // MARK: - Validation

    private func validate() -> (valid: Bool, error: String?) {
        // AE Title
        let aeTitle = aeTitleField.stringValue.trimmingCharacters(in: .whitespaces)
        if aeTitle.isEmpty {
            return (false, "AE Title cannot be empty")
        }
        if aeTitle.count > 16 {
            return (false, "AE Title cannot exceed 16 characters")
        }

        // Hostname
        let hostname = hostnameField.stringValue.trimmingCharacters(in: .whitespaces)
        if hostname.isEmpty {
            return (false, "Hostname cannot be empty")
        }

        // Port
        let portString = portField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let port = Int(portString), port > 0, port <= 65535 else {
            return (false, "Port must be a number between 1 and 65535")
        }

        // Capabilities
        if queryRetrieveCheckbox.state == .off && storageCheckbox.state == .off {
            return (false, "At least one capability (Query/Retrieve or Storage) must be selected")
        }

        return (true, nil)
    }

    // MARK: - Actions

    @objc private func save() {
        // Validate
        let validation = validate()
        guard validation.valid else {
            showError(validation.error ?? "Invalid input")
            return
        }

        // Create or update node
        let aeTitle = aeTitleField.stringValue.trimmingCharacters(in: .whitespaces)
        let hostname = hostnameField.stringValue.trimmingCharacters(in: .whitespaces)
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 104
        let description = descriptionField.stringValue.trimmingCharacters(in: .whitespaces)
        let isQueryRetrieve = queryRetrieveCheckbox.state == .on
        let isStorage = storageCheckbox.state == .on
        let isActive = activeCheckbox.state == .on

        var updatedNode = DicomNode(
            id: node?.id,
            aeTitle: aeTitle,
            hostname: hostname,
            port: port,
            description: description.isEmpty ? nil : description,
            isQueryRetrieve: isQueryRetrieve,
            isStorage: isStorage,
            isActive: isActive
        )

        // Save to database
        guard let database = database else {
            showError("Database not available")
            return
        }

        do {
            if node == nil {
                // Insert new node
                _ = try database.insertDicomNode(updatedNode)
            } else {
                // Update existing node
                try database.updateDicomNode(updatedNode)
            }

            // Notify and close
            onSave?()
            dismiss(nil)
        } catch {
            if let nodeError = error as? DicomNodeError {
                showError(nodeError.localizedDescription)
            } else {
                showError("Failed to save PACS node: \(error.localizedDescription)")
            }
        }
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    // MARK: - UI Helpers

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Validation Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: view.window!, completionHandler: nil)
    }
}

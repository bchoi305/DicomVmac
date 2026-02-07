//
//  AnonymizationSettingsViewController.swift
//  DicomVmac
//
//  UI for configuring DICOM anonymization profiles and settings.
//

import AppKit

/// View controller for anonymization settings
final class AnonymizationSettingsViewController: NSViewController {

    private let anonymizationService: DicomAnonymizationService
    private let database: DatabaseManager

    private var currentProfile: AnonymizationProfile
    private var selectedFiles: [String] = []

    // UI Elements
    private let profilePopup = NSPopUpButton()
    private let tagRulesTableView = NSTableView()
    private let tagRulesScrollView = NSScrollView()

    private let dateShiftPopup = NSPopUpButton()
    private let dateShiftDaysField = NSTextField()
    private let dateShiftDaysLabel = NSTextField(labelWithString: "Days:")
    private let dateShiftStack = NSStackView()

    private let patientIDStrategyPopup = NSPopUpButton()
    private let patientIDPrefixField = NSTextField()
    private let patientIDPrefixLabel = NSTextField(labelWithString: "Prefix:")
    private let patientIDPrefixStack = NSStackView()
    private let maintainMappingCheckbox = NSButton(checkboxWithTitle: "Maintain patient mapping", target: nil, action: nil)

    private let replaceStudyUIDCheckbox = NSButton(checkboxWithTitle: "Replace Study Instance UID", target: nil, action: nil)
    private let replaceSeriesUIDCheckbox = NSButton(checkboxWithTitle: "Replace Series Instance UID", target: nil, action: nil)
    private let replaceSOPUIDCheckbox = NSButton(checkboxWithTitle: "Replace SOP Instance UID", target: nil, action: nil)

    private let removePrivateTagsCheckbox = NSButton(checkboxWithTitle: "Remove private tags", target: nil, action: nil)
    private let removeCurvesCheckbox = NSButton(checkboxWithTitle: "Remove curves", target: nil, action: nil)
    private let removeOverlaysCheckbox = NSButton(checkboxWithTitle: "Remove overlays", target: nil, action: nil)

    private let previewButton = NSButton(title: "Preview Changes", target: nil, action: #selector(previewChanges))
    private let applyButton = NSButton(title: "Apply", target: nil, action: #selector(applyAnonymization))
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: #selector(cancel))

    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

    init(
        anonymizationService: DicomAnonymizationService,
        database: DatabaseManager,
        selectedFiles: [String] = []
    ) {
        self.anonymizationService = anonymizationService
        self.database = database
        self.selectedFiles = selectedFiles
        self.currentProfile = AnonymizationProfile.basicProfile
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateUIFromProfile()
    }

    private func setupUI() {
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Profile Selection
        contentStack.addArrangedSubview(createSectionLabel("Anonymization Profile"))
        contentStack.addArrangedSubview(createProfileSection())

        // Tag Rules
        contentStack.addArrangedSubview(createSectionLabel("Tag Rules"))
        contentStack.addArrangedSubview(createTagRulesSection())

        // Date Shift Settings
        contentStack.addArrangedSubview(createSectionLabel("Date Handling"))
        contentStack.addArrangedSubview(createDateShiftSection())

        // Patient ID Settings
        contentStack.addArrangedSubview(createSectionLabel("Patient ID Mapping"))
        contentStack.addArrangedSubview(createPatientIDSection())

        // UID Settings
        contentStack.addArrangedSubview(createSectionLabel("UID Replacement"))
        contentStack.addArrangedSubview(createUIDSection())

        // Privacy Options
        contentStack.addArrangedSubview(createSectionLabel("Privacy Options"))
        contentStack.addArrangedSubview(createPrivacySection())

        // Progress
        contentStack.addArrangedSubview(createProgressSection())

        // Buttons
        contentStack.addArrangedSubview(createButtonSection())
    }

    private func createSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        return label
    }

    private func createProfileSection() -> NSView {
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: AnonymizationProfile.builtInProfiles.map { $0.name })
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)

        let row = createRow("Profile:", profilePopup)
        return row
    }

    private func createTagRulesSection() -> NSView {
        // Setup table view
        let column1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tagName"))
        column1.title = "Tag"
        column1.width = 150

        let column2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tagCode"))
        column2.title = "Code"
        column2.width = 100

        let column3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        column3.title = "Action"
        column3.width = 120

        let column4 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("replacement"))
        column4.title = "Replacement"
        column4.width = 150

        tagRulesTableView.addTableColumn(column1)
        tagRulesTableView.addTableColumn(column2)
        tagRulesTableView.addTableColumn(column3)
        tagRulesTableView.addTableColumn(column4)
        tagRulesTableView.headerView = NSTableHeaderView()
        tagRulesTableView.dataSource = self
        tagRulesTableView.delegate = self

        tagRulesScrollView.documentView = tagRulesTableView
        tagRulesScrollView.hasVerticalScroller = true
        tagRulesScrollView.translatesAutoresizingMaskIntoConstraints = false
        tagRulesScrollView.heightAnchor.constraint(equalToConstant: 200).isActive = true

        return tagRulesScrollView
    }

    private func createDateShiftSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        // Date shift strategy popup
        dateShiftPopup.removeAllItems()
        dateShiftPopup.addItems(withTitles: DateShiftStrategy.allCases.map { $0.rawValue })
        dateShiftPopup.target = self
        dateShiftPopup.action = #selector(dateShiftStrategyChanged)

        let strategyRow = createRow("Strategy:", dateShiftPopup)
        stack.addArrangedSubview(strategyRow)

        // Fixed date shift amount
        dateShiftDaysField.placeholderString = "0"
        dateShiftDaysField.stringValue = "0"
        dateShiftDaysField.widthAnchor.constraint(equalToConstant: 100).isActive = true

        dateShiftStack.orientation = .horizontal
        dateShiftStack.spacing = 8
        dateShiftStack.addArrangedSubview(dateShiftDaysLabel)
        dateShiftStack.addArrangedSubview(dateShiftDaysField)
        dateShiftStack.addArrangedSubview(NSView())  // Spacer
        dateShiftStack.isHidden = true

        stack.addArrangedSubview(dateShiftStack)

        return stack
    }

    private func createPatientIDSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        // Strategy popup
        patientIDStrategyPopup.removeAllItems()
        patientIDStrategyPopup.addItems(withTitles: PatientIDMappingStrategy.allCases.map { $0.rawValue })
        patientIDStrategyPopup.target = self
        patientIDStrategyPopup.action = #selector(patientIDStrategyChanged)

        let strategyRow = createRow("Strategy:", patientIDStrategyPopup)
        stack.addArrangedSubview(strategyRow)

        // Custom prefix
        patientIDPrefixField.placeholderString = "ANON"
        patientIDPrefixField.stringValue = currentProfile.patientIDPrefix
        patientIDPrefixField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        patientIDPrefixStack.orientation = .horizontal
        patientIDPrefixStack.spacing = 8
        patientIDPrefixStack.addArrangedSubview(patientIDPrefixLabel)
        patientIDPrefixStack.addArrangedSubview(patientIDPrefixField)
        patientIDPrefixStack.addArrangedSubview(NSView())  // Spacer

        stack.addArrangedSubview(patientIDPrefixStack)

        // Maintain mapping checkbox
        maintainMappingCheckbox.state = currentProfile.maintainPatientMapping ? .on : .off
        stack.addArrangedSubview(maintainMappingCheckbox)

        return stack
    }

    private func createUIDSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4

        replaceStudyUIDCheckbox.state = currentProfile.replaceStudyInstanceUID ? .on : .off
        replaceSeriesUIDCheckbox.state = currentProfile.replaceSeriesInstanceUID ? .on : .off
        replaceSOPUIDCheckbox.state = currentProfile.replaceSOPInstanceUID ? .on : .off

        stack.addArrangedSubview(replaceStudyUIDCheckbox)
        stack.addArrangedSubview(replaceSeriesUIDCheckbox)
        stack.addArrangedSubview(replaceSOPUIDCheckbox)

        return stack
    }

    private func createPrivacySection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4

        removePrivateTagsCheckbox.state = currentProfile.removePrivateTags ? .on : .off
        removeCurvesCheckbox.state = currentProfile.removeCurves ? .on : .off
        removeOverlaysCheckbox.state = currentProfile.removeOverlays ? .on : .off

        stack.addArrangedSubview(removePrivateTagsCheckbox)
        stack.addArrangedSubview(removeCurvesCheckbox)
        stack.addArrangedSubview(removeOverlaysCheckbox)

        return stack
    }

    private func createProgressSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.isHidden = true

        statusLabel.isHidden = true
        statusLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(progressIndicator)
        stack.addArrangedSubview(statusLabel)

        return stack
    }

    private func createButtonSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually

        previewButton.target = self
        previewButton.action = #selector(previewChanges)

        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        applyButton.target = self
        applyButton.action = #selector(applyAnonymization)
        applyButton.keyEquivalent = "\r"

        stack.addArrangedSubview(NSView())  // Spacer
        stack.addArrangedSubview(previewButton)
        stack.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(applyButton)

        return stack
    }

    private func createRow(_ label: String, _ controls: NSView...) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY

        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 100).isActive = true

        stack.addArrangedSubview(labelField)

        for control in controls {
            stack.addArrangedSubview(control)
        }

        return stack
    }

    // MARK: - Actions

    @objc private func profileChanged() {
        let selectedIndex = profilePopup.indexOfSelectedItem
        if selectedIndex >= 0 && selectedIndex < AnonymizationProfile.builtInProfiles.count {
            currentProfile = AnonymizationProfile.builtInProfiles[selectedIndex]
            updateUIFromProfile()
        }
    }

    @objc private func dateShiftStrategyChanged() {
        let selectedIndex = dateShiftPopup.indexOfSelectedItem
        if selectedIndex >= 0 && selectedIndex < DateShiftStrategy.allCases.count {
            currentProfile.dateShiftStrategy = DateShiftStrategy.allCases[selectedIndex]
            dateShiftStack.isHidden = (currentProfile.dateShiftStrategy != .fixed)
        }
    }

    @objc private func patientIDStrategyChanged() {
        let selectedIndex = patientIDStrategyPopup.indexOfSelectedItem
        if selectedIndex >= 0 && selectedIndex < PatientIDMappingStrategy.allCases.count {
            currentProfile.patientIDStrategy = PatientIDMappingStrategy.allCases[selectedIndex]
            patientIDPrefixStack.isHidden = (currentProfile.patientIDStrategy != .custom)
        }
    }

    @objc private func previewChanges() {
        let alert = NSAlert()
        alert.messageText = "Anonymization Preview"
        alert.informativeText = buildPreviewText()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func applyAnonymization() {
        guard !selectedFiles.isEmpty else {
            showAlert("No files selected for anonymization")
            return
        }

        // Update profile from UI
        updateProfileFromUI()

        // Show confirmation
        let alert = NSAlert()
        alert.messageText = "Confirm Anonymization"
        alert.informativeText = "Anonymize \(selectedFiles.count) file(s) with profile '\(currentProfile.name)'?\n\nThis operation cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Anonymize")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Perform anonymization
        applyButton.isEnabled = false
        progressIndicator.isHidden = false
        progressIndicator.doubleValue = 0
        statusLabel.isHidden = false
        statusLabel.stringValue = "Anonymizing 0 of \(selectedFiles.count)..."

        Task {
            do {
                // Create output directory
                let outputDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Anonymized_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

                // Build file pairs
                let filePairs = selectedFiles.map { inputPath in
                    let filename = URL(fileURLWithPath: inputPath).lastPathComponent
                    let outputPath = outputDir.appendingPathComponent(filename).path
                    return (input: inputPath, output: outputPath)
                }

                let result = try await anonymizationService.anonymizeFiles(
                    files: filePairs,
                    profile: currentProfile
                ) { completed, total in
                    Task { @MainActor in
                        self.progressIndicator.doubleValue = Double(completed) / Double(total) * 100.0
                        self.statusLabel.stringValue = "Anonymizing \(completed) of \(total)..."
                    }
                }

                await MainActor.run {
                    self.progressIndicator.isHidden = true
                    self.statusLabel.stringValue = result.summary

                    if result.isSuccess {
                        self.statusLabel.textColor = .systemGreen
                        // Reveal in Finder
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputDir.path)
                    } else {
                        self.statusLabel.textColor = .systemRed
                        self.showAlert("Anonymization completed with errors:\n" + result.errors.joined(separator: "\n"))
                    }

                    self.applyButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    self.progressIndicator.isHidden = true
                    self.applyButton.isEnabled = true
                    self.showAlert("Anonymization failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func cancel() {
        view.window?.close()
    }

    // MARK: - Helper Methods

    private func updateUIFromProfile() {
        // Update all UI elements from current profile
        tagRulesTableView.reloadData()

        // Date shift
        if let index = DateShiftStrategy.allCases.firstIndex(of: currentProfile.dateShiftStrategy) {
            dateShiftPopup.selectItem(at: index)
        }
        dateShiftStack.isHidden = (currentProfile.dateShiftStrategy != .fixed)
        dateShiftDaysField.stringValue = "\(currentProfile.dateShiftDays ?? 0)"

        // Patient ID
        if let index = PatientIDMappingStrategy.allCases.firstIndex(of: currentProfile.patientIDStrategy) {
            patientIDStrategyPopup.selectItem(at: index)
        }
        patientIDPrefixStack.isHidden = (currentProfile.patientIDStrategy != .custom)
        patientIDPrefixField.stringValue = currentProfile.patientIDPrefix
        maintainMappingCheckbox.state = currentProfile.maintainPatientMapping ? .on : .off

        // UIDs
        replaceStudyUIDCheckbox.state = currentProfile.replaceStudyInstanceUID ? .on : .off
        replaceSeriesUIDCheckbox.state = currentProfile.replaceSeriesInstanceUID ? .on : .off
        replaceSOPUIDCheckbox.state = currentProfile.replaceSOPInstanceUID ? .on : .off

        // Privacy
        removePrivateTagsCheckbox.state = currentProfile.removePrivateTags ? .on : .off
        removeCurvesCheckbox.state = currentProfile.removeCurves ? .on : .off
        removeOverlaysCheckbox.state = currentProfile.removeOverlays ? .on : .off
    }

    private func updateProfileFromUI() {
        // Update profile from UI elements
        if currentProfile.dateShiftStrategy == .fixed {
            currentProfile.dateShiftDays = Int(dateShiftDaysField.stringValue)
        }

        currentProfile.patientIDPrefix = patientIDPrefixField.stringValue
        currentProfile.maintainPatientMapping = maintainMappingCheckbox.state == .on

        currentProfile.replaceStudyInstanceUID = replaceStudyUIDCheckbox.state == .on
        currentProfile.replaceSeriesInstanceUID = replaceSeriesUIDCheckbox.state == .on
        currentProfile.replaceSOPInstanceUID = replaceSOPUIDCheckbox.state == .on

        currentProfile.removePrivateTags = removePrivateTagsCheckbox.state == .on
        currentProfile.removeCurves = removeCurvesCheckbox.state == .on
        currentProfile.removeOverlays = removeOverlaysCheckbox.state == .on
    }

    private func buildPreviewText() -> String {
        var text = "Profile: \(currentProfile.name)\n\n"
        text += "Tag Rules (\(currentProfile.tagRules.count)):\n"
        for rule in currentProfile.tagRules.prefix(5) {
            text += "  • \(rule.tagName) \(rule.tagCode): \(rule.action.rawValue)\n"
        }
        if currentProfile.tagRules.count > 5 {
            text += "  ... and \(currentProfile.tagRules.count - 5) more\n"
        }

        text += "\nDate Handling: \(currentProfile.dateShiftStrategy.rawValue)\n"
        text += "Patient ID: \(currentProfile.patientIDStrategy.rawValue)\n"
        text += "Replace UIDs: Study=\(currentProfile.replaceStudyInstanceUID), Series=\(currentProfile.replaceSeriesInstanceUID), SOP=\(currentProfile.replaceSOPInstanceUID)\n"
        text += "Remove Private Tags: \(currentProfile.removePrivateTags)\n"

        return text
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Anonymization"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Table View Data Source

extension AnonymizationSettingsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return currentProfile.tagRules.count
    }
}

// MARK: - Table View Delegate

extension AnonymizationSettingsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < currentProfile.tagRules.count else { return nil }

        let rule = currentProfile.tagRules[row]
        let identifier = tableColumn?.identifier.rawValue ?? ""

        let cellView = NSTextField(labelWithString: "")
        cellView.isBordered = false
        cellView.backgroundColor = .clear

        switch identifier {
        case "tagName":
            cellView.stringValue = rule.tagName
        case "tagCode":
            cellView.stringValue = rule.tagCode
        case "action":
            cellView.stringValue = rule.action.rawValue
        case "replacement":
            cellView.stringValue = rule.replacementValue ?? ""
        default:
            break
        }

        return cellView
    }
}

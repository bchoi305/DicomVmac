//
//  ExportViewController.swift
//  DicomVmac
//
//  Export configuration dialog for converting DICOM images to standard formats.
//

import AppKit

/// View controller for DICOM export configuration
final class ExportViewController: NSViewController {

    // Services
    private let exportService: DicomExportService
    private let database: DatabaseManager

    // Export state
    private var options = DicomExportOptions()
    private var currentInstance: Instance?
    private var currentSeriesRowID: Int64?
    private var currentStudyRowID: Int64?

    // UI Elements
    private let formatPopup = NSPopUpButton()
    private let qualitySlider = NSSlider()
    private let qualityLabel = NSTextField(labelWithString: "Quality: 90%")
    private let use16BitCheckbox = NSButton(checkboxWithTitle: "Use 16-bit (PNG/TIFF)", target: nil, action: nil)

    private let windowPresetPopup = NSPopUpButton()
    private let customCenterField = NSTextField()
    private let customWidthField = NSTextField()
    private let customWindowStack = NSStackView()

    private var scopeButtons: [NSButton] = []
    private let namingPopup = NSPopUpButton()
    private let customPatternField = NSTextField()
    private let subfoldersCheckbox = NSButton(checkboxWithTitle: "Create subfolders per series", target: nil, action: nil)

    private let anonymizeCheckbox = NSButton(checkboxWithTitle: "Anonymize (strip patient info)", target: nil, action: nil)
    private let embedMetadataCheckbox = NSButton(checkboxWithTitle: "Embed metadata", target: nil, action: nil)

    private let destinationLabel = NSTextField(labelWithString: "No destination selected")
    private let chooseButton = NSButton(title: "Choose...", target: nil, action: #selector(chooseDestination))

    private let exportButton = NSButton(title: "Export", target: nil, action: #selector(performExport))
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: #selector(cancel))

    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

    init(
        exportService: DicomExportService,
        database: DatabaseManager,
        currentInstance: Instance? = nil,
        currentSeriesRowID: Int64? = nil,
        currentStudyRowID: Int64? = nil
    ) {
        self.exportService = exportService
        self.database = database
        self.currentInstance = currentInstance
        self.currentSeriesRowID = currentSeriesRowID
        self.currentStudyRowID = currentStudyRowID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateUIForOptions()
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

        // Format Section
        contentStack.addArrangedSubview(createSectionLabel("Format"))
        contentStack.addArrangedSubview(createFormatSection())

        // Window/Level Section
        contentStack.addArrangedSubview(createSectionLabel("Window/Level"))
        contentStack.addArrangedSubview(createWindowSection())

        // Scope Section
        contentStack.addArrangedSubview(createSectionLabel("Export Scope"))
        contentStack.addArrangedSubview(createScopeSection())

        // Naming Section
        contentStack.addArrangedSubview(createSectionLabel("File Naming"))
        contentStack.addArrangedSubview(createNamingSection())

        // Options Section
        contentStack.addArrangedSubview(createSectionLabel("Options"))
        contentStack.addArrangedSubview(createOptionsSection())

        // Destination Section
        contentStack.addArrangedSubview(createSectionLabel("Destination"))
        contentStack.addArrangedSubview(createDestinationSection())

        // Progress Section
        contentStack.addArrangedSubview(createProgressSection())

        // Buttons
        contentStack.addArrangedSubview(createButtonSection())
    }

    private func createSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        return label
    }

    private func createFormatSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        // Format popup
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: ExportFormat.allCases.map { $0.rawValue })
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        let formatRow = createRow("Format:", formatPopup)
        stack.addArrangedSubview(formatRow)

        // Quality slider
        qualitySlider.minValue = 0.1
        qualitySlider.maxValue = 1.0
        qualitySlider.doubleValue = options.quality
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)

        let qualityRow = createRow("Quality:", qualitySlider, qualityLabel)
        stack.addArrangedSubview(qualityRow)

        // 16-bit checkbox
        use16BitCheckbox.target = self
        use16BitCheckbox.action = #selector(use16BitChanged)
        stack.addArrangedSubview(use16BitCheckbox)

        return stack
    }

    private func createWindowSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        // Window preset popup
        windowPresetPopup.removeAllItems()
        windowPresetPopup.addItems(withTitles: ExportWindowPreset.allCases.map { $0.rawValue })
        windowPresetPopup.target = self
        windowPresetPopup.action = #selector(windowPresetChanged)

        let presetRow = createRow("Preset:", windowPresetPopup)
        stack.addArrangedSubview(presetRow)

        // Custom window/level (initially hidden)
        customCenterField.placeholderString = "Window Center"
        customCenterField.stringValue = "\(options.customWindowCenter)"

        customWidthField.placeholderString = "Window Width"
        customWidthField.stringValue = "\(options.customWindowWidth)"

        customWindowStack.orientation = .horizontal
        customWindowStack.spacing = 8
        customWindowStack.addArrangedSubview(NSTextField(labelWithString: "Center:"))
        customWindowStack.addArrangedSubview(customCenterField)
        customWindowStack.addArrangedSubview(NSTextField(labelWithString: "Width:"))
        customWindowStack.addArrangedSubview(customWidthField)
        customWindowStack.isHidden = true

        stack.addArrangedSubview(customWindowStack)

        return stack
    }

    private func createScopeSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4

        for scope in ExportScope.allCases {
            let button = NSButton(radioButtonWithTitle: scope.rawValue, target: self, action: #selector(scopeChanged))
            scopeButtons.append(button)
            stack.addArrangedSubview(button)
        }

        // Select "Current Series" by default
        if scopeButtons.count > 1 {
            scopeButtons[1].state = .on
        }

        return stack
    }

    private func createNamingSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        // Naming convention popup
        namingPopup.removeAllItems()
        namingPopup.addItems(withTitles: ExportNamingConvention.allCases.map { $0.rawValue })
        namingPopup.target = self
        namingPopup.action = #selector(namingChanged)

        let namingRow = createRow("Convention:", namingPopup)
        stack.addArrangedSubview(namingRow)

        // Custom pattern field (initially hidden)
        customPatternField.placeholderString = "e.g., {PatientID}_{SeriesNumber}_{Index}"
        customPatternField.isHidden = true
        stack.addArrangedSubview(customPatternField)

        // Subfolders checkbox
        subfoldersCheckbox.state = options.includeSubfolders ? .on : .off
        subfoldersCheckbox.target = self
        subfoldersCheckbox.action = #selector(subfoldersChanged)
        stack.addArrangedSubview(subfoldersCheckbox)

        return stack
    }

    private func createOptionsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        embedMetadataCheckbox.state = options.embedMetadata ? .on : .off
        embedMetadataCheckbox.target = self
        embedMetadataCheckbox.action = #selector(embedMetadataChanged)
        stack.addArrangedSubview(embedMetadataCheckbox)

        anonymizeCheckbox.state = options.anonymize ? .on : .off
        anonymizeCheckbox.target = self
        anonymizeCheckbox.action = #selector(anonymizeChanged)
        stack.addArrangedSubview(anonymizeCheckbox)

        return stack
    }

    private func createDestinationSection() -> NSView {
        chooseButton.target = self
        chooseButton.action = #selector(chooseDestination)

        let row = createRow("Folder:", destinationLabel, chooseButton)
        return row
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

        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        exportButton.target = self
        exportButton.action = #selector(performExport)
        exportButton.keyEquivalent = "\r"

        stack.addArrangedSubview(NSView()) // Spacer
        stack.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(exportButton)

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

    @objc private func formatChanged() {
        let formatIndex = formatPopup.indexOfSelectedItem
        if formatIndex >= 0 && formatIndex < ExportFormat.allCases.count {
            options.format = ExportFormat.allCases[formatIndex]
            updateUIForOptions()
        }
    }

    @objc private func qualityChanged() {
        options.quality = qualitySlider.doubleValue
        qualityLabel.stringValue = String(format: "Quality: %.0f%%", options.quality * 100)
    }

    @objc private func use16BitChanged() {
        options.use16Bit = use16BitCheckbox.state == .on
    }

    @objc private func windowPresetChanged() {
        let presetIndex = windowPresetPopup.indexOfSelectedItem
        if presetIndex >= 0 && presetIndex < ExportWindowPreset.allCases.count {
            options.windowPreset = ExportWindowPreset.allCases[presetIndex]
            customWindowStack.isHidden = (options.windowPreset != .custom)
        }
    }

    @objc private func scopeChanged() {
        for (index, button) in scopeButtons.enumerated() {
            if button.state == .on {
                if index < ExportScope.allCases.count {
                    options.scope = ExportScope.allCases[index]
                }
                break
            }
        }
    }

    @objc private func namingChanged() {
        let namingIndex = namingPopup.indexOfSelectedItem
        if namingIndex >= 0 && namingIndex < ExportNamingConvention.allCases.count {
            options.namingConvention = ExportNamingConvention.allCases[namingIndex]
            customPatternField.isHidden = (options.namingConvention != .custom)
        }
    }

    @objc private func subfoldersChanged() {
        options.includeSubfolders = subfoldersCheckbox.state == .on
    }

    @objc private func embedMetadataChanged() {
        options.embedMetadata = embedMetadataCheckbox.state == .on
    }

    @objc private func anonymizeChanged() {
        options.anonymize = anonymizeCheckbox.state == .on
    }

    @objc private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Destination"

        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.options.destinationURL = url
            self.destinationLabel.stringValue = url.path
        }
    }

    @objc private func performExport() {
        // Validate
        guard options.destinationURL != nil else {
            showAlert("Please select a destination folder")
            return
        }

        // Get custom window values if needed
        if options.windowPreset == .custom {
            if let center = Double(customCenterField.stringValue),
               let width = Double(customWidthField.stringValue) {
                options.customWindowCenter = center
                options.customWindowWidth = width
            } else {
                showAlert("Please enter valid window center and width values")
                return
            }
        }

        // Get custom pattern if needed
        if options.namingConvention == .custom {
            options.customPattern = customPatternField.stringValue
            if options.customPattern.isEmpty {
                showAlert("Please enter a custom naming pattern")
                return
            }
        }

        // Get instances to export
        let instances: [Instance]
        do {
            instances = try exportService.getInstances(
                for: options.scope,
                currentInstance: currentInstance,
                currentSeriesRowID: currentSeriesRowID,
                currentStudyRowID: currentStudyRowID
            )
        } catch {
            showAlert("Error: \(error.localizedDescription)")
            return
        }

        guard !instances.isEmpty else {
            showAlert("No images to export")
            return
        }

        // Start export
        exportButton.isEnabled = false
        cancelButton.title = "Close"
        progressIndicator.isHidden = false
        progressIndicator.doubleValue = 0
        statusLabel.isHidden = false
        statusLabel.stringValue = "Exporting 0 of \(instances.count)..."

        Task {
            do {
                let result = try await exportService.export(
                    instances: instances,
                    options: options
                ) { completed, total in
                    Task { @MainActor in
                        self.progressIndicator.doubleValue = Double(completed) / Double(total) * 100.0
                        self.statusLabel.stringValue = "Exporting \(completed) of \(total)..."
                    }
                }

                await MainActor.run {
                    self.progressIndicator.isHidden = true
                    self.statusLabel.stringValue = result.summary

                    if result.isSuccess {
                        self.statusLabel.textColor = .systemGreen
                        // Reveal in Finder
                        if let firstFile = result.exportedFiles.first {
                            NSWorkspace.shared.selectFile(firstFile.path, inFileViewerRootedAtPath: "")
                        }
                    } else {
                        self.statusLabel.textColor = .systemRed
                        self.showAlert("Export completed with errors:\n" + result.errors.joined(separator: "\n"))
                    }
                }
            } catch {
                await MainActor.run {
                    self.progressIndicator.isHidden = true
                    self.exportButton.isEnabled = true
                    self.cancelButton.title = "Cancel"
                    self.showAlert("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func cancel() {
        view.window?.close()
    }

    private func updateUIForOptions() {
        // Enable/disable quality slider based on format
        let supportsQuality = options.format.supportsCompression
        qualitySlider.isEnabled = supportsQuality
        qualityLabel.textColor = supportsQuality ? .labelColor : .disabledControlTextColor

        // Enable/disable 16-bit checkbox based on format
        let supports16Bit = options.format.supports16Bit
        use16BitCheckbox.isEnabled = supports16Bit
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

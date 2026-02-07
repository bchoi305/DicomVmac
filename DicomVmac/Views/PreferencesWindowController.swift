//
//  PreferencesWindowController.swift
//  DicomVmac
//
//  Window controller for application preferences, primarily PACS node management.
//

import Cocoa

/// Window controller for the preferences window
final class PreferencesWindowController: NSWindowController {

    /// Shared instance (singleton)
    static let shared = PreferencesWindowController()

    private init() {
        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.minSize = NSSize(width: 600, height: 400)

        super.init(window: window)

        // Set up content
        setupContent()

        // Center window
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        guard let window = window else { return }

        // Create tab view controller for future expansion (PACS nodes, general settings, etc.)
        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar

        // PACS Nodes tab
        let nodeListVC = DicomNodeListViewController()
        let nodeTabItem = NSTabViewItem(viewController: nodeListVC)
        nodeTabItem.label = "PACS Nodes"
        nodeTabItem.image = NSImage(systemSymbolName: "network", accessibilityDescription: "PACS Nodes")
        tabViewController.addTabViewItem(nodeTabItem)

        // Set as content
        window.contentViewController = tabViewController
    }

    /// Show the preferences window
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

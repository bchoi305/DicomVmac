//
//  HangingProtocol.swift
//  DicomVmac
//
//  Defines viewer layout configurations for comparing studies/series.
//

import Foundation

/// Defines a viewer layout configuration.
struct HangingProtocol: Identifiable, Equatable {
    let id: String
    let name: String
    let rows: Int
    let cols: Int
    let keyEquivalent: String?

    /// Total number of viewer cells in this layout.
    var cellCount: Int { rows * cols }

    /// Standard layout presets.
    static let layouts: [HangingProtocol] = [
        HangingProtocol(id: "1x1", name: "1×1", rows: 1, cols: 1, keyEquivalent: "1"),
        HangingProtocol(id: "1x2", name: "1×2", rows: 1, cols: 2, keyEquivalent: "2"),
        HangingProtocol(id: "2x1", name: "2×1", rows: 2, cols: 1, keyEquivalent: "3"),
        HangingProtocol(id: "2x2", name: "2×2", rows: 2, cols: 2, keyEquivalent: "4"),
    ]

    /// Default 1×1 layout.
    static let `default` = layouts[0]

    /// Find a layout by its ID.
    static func layout(withID id: String) -> HangingProtocol? {
        layouts.first { $0.id == id }
    }
}

/// Linking options between viewers.
struct ViewerLinkOptions: OptionSet, Sendable {
    let rawValue: Int

    /// Synchronize slice scrolling between viewers.
    static let scroll = ViewerLinkOptions(rawValue: 1 << 0)

    /// Synchronize window/level adjustments between viewers.
    static let windowLevel = ViewerLinkOptions(rawValue: 1 << 1)

    /// Synchronize zoom level between viewers.
    static let zoom = ViewerLinkOptions(rawValue: 1 << 2)

    /// All linking options enabled.
    static let all: ViewerLinkOptions = [.scroll, .windowLevel, .zoom]

    /// No linking (viewers are independent).
    static let none: ViewerLinkOptions = []
}

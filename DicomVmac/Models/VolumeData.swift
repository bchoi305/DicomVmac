//
//  VolumeData.swift
//  DicomVmac
//
//  Data models for 3D volume representation used in MPR and Volume Rendering.
//

import Foundation

// MARK: - Volume Rendering Mode

/// Volume rendering modes for 3D visualization.
enum VolumeRenderMode: Int, CaseIterable, Sendable {
    case slice = 0      // Standard MPR slice view
    case mip = 1        // Maximum Intensity Projection
    case minip = 2      // Minimum Intensity Projection
    case aip = 3        // Average Intensity Projection
    case vr = 4         // Volume Rendering with transfer function

    var displayName: String {
        switch self {
        case .slice: return "Slice"
        case .mip: return "MIP"
        case .minip: return "MinIP"
        case .aip: return "AIP"
        case .vr: return "Volume Rendering"
        }
    }

    /// Whether this mode requires ray marching through the volume.
    var isProjectionMode: Bool {
        self != .slice
    }
}

/// Preset transfer functions for Volume Rendering mode.
enum VRPreset: String, CaseIterable, Sendable {
    case bone = "bone"              // High HU values (skeletal structures)
    case softTissue = "softTissue"  // Mid HU values (organs, muscles)
    case lung = "lung"              // Low HU values (air, lung tissue)
    case angio = "angio"            // Contrast-enhanced vessels

    var displayName: String {
        switch self {
        case .bone: return "Bone"
        case .softTissue: return "Soft Tissue"
        case .lung: return "Lung"
        case .angio: return "Angio"
        }
    }
}

// MARK: - Volume Data

/// Metadata describing a loaded 3D volume for MPR rendering.
struct VolumeData: Sendable {
    let seriesRowID: Int64
    let width: Int       // X dimension (columns)
    let height: Int      // Y dimension (rows)
    let depth: Int       // Z dimension (slices)
    let pixelSpacingX: Double   // mm per pixel in X (column) direction
    let pixelSpacingY: Double   // mm per pixel in Y (row) direction
    let sliceSpacing: Double    // mm between slices in Z direction
    let rescaleSlope: Double
    let rescaleIntercept: Double
    let windowCenter: Double
    let windowWidth: Double
    let bitsStored: Int
}

/// Normalized slice positions for MPR views (0.0 to 1.0 range).
struct MPRSlicePosition: Equatable, Sendable {
    var axial: Float      // Z position (0-1), slice in XY plane
    var coronal: Float    // Y position (0-1), slice in XZ plane
    var sagittal: Float   // X position (0-1), slice in YZ plane

    static let center = MPRSlicePosition(axial: 0.5, coronal: 0.5, sagittal: 0.5)
}

/// The three orthogonal planes in MPR visualization, plus 3D projection.
enum MPRPlane: Int, CaseIterable, Sendable {
    case axial = 0      // XY plane, scrolling through Z
    case coronal = 1    // XZ plane, scrolling through Y
    case sagittal = 2   // YZ plane, scrolling through X
    case projection = 3 // 3D projection view (MIP, VR, etc.)

    var displayName: String {
        switch self {
        case .axial: return "Axial"
        case .coronal: return "Coronal"
        case .sagittal: return "Sagittal"
        case .projection: return "3D View"
        }
    }

    /// Whether this plane supports rotation (only projection mode).
    var supportsRotation: Bool {
        self == .projection
    }
}

/// Error types for volume loading operations.
enum VolumeLoadError: Error, LocalizedError {
    case noInstances
    case inconsistentDimensions
    case decodeFailed(sopInstanceUID: String, underlying: Error)
    case insufficientSlices(count: Int)

    var errorDescription: String? {
        switch self {
        case .noInstances:
            return "No instances found in series"
        case .inconsistentDimensions:
            return "Slices have inconsistent dimensions"
        case .decodeFailed(let uid, let error):
            return "Failed to decode instance \(uid): \(error.localizedDescription)"
        case .insufficientSlices(let count):
            return "MPR requires at least 3 slices, found \(count)"
        }
    }
}

# DicomVmac

A high-performance DICOM medical image viewer for macOS with advanced visualization, PACS integration, and privacy-preserving tools.

![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

### 🖼️ Core Viewing
- **High-performance rendering** with Metal GPU acceleration
- **Window/Level adjustments** with preset configurations (lung, bone, brain, etc.)
- **Zoom and pan** with smooth gestures
- **Measurement tools** for distance and angle calculations
- **Annotations** with persistent overlay support
- **Frame caching** for instant slice navigation

### 🌐 PACS Integration
- **C-ECHO** - Connectivity verification
- **C-FIND** - Query remote PACS for studies
- **C-MOVE** - Retrieve studies directly into local database
- **C-STORE** - Send studies to PACS servers
- **Multiple PACS** configuration and management
- **Asynchronous operations** with progress tracking

### 📤 Export & Conversion
- **Multiple formats** - JPEG, PNG, TIFF
- **Quality control** with adjustable compression
- **Window/Level presets** for optimal visualization
- **Batch export** for series/studies
- **Flexible naming** conventions
- **Medical imaging optimized** output

### 🔒 Anonymization
- **Profile-based** anonymization (Basic, Full, Research)
- **HIPAA/GDPR compliant** tag removal
- **Patient ID mapping** with hash or sequential strategies
- **Date shifting** for temporal privacy
- **UID regeneration** maintaining relationships
- **Batch processing** with mapping export

### 🔄 Multi-Planar Reconstruction (MPR)
- **Real-time 3D** volume reconstruction
- **Three orthogonal planes** (axial, sagittal, coronal)
- **Synchronized scrolling** across views
- **Linked window/level** adjustments
- **GPU-accelerated** rendering (60 FPS)
- **Trilinear interpolation** for smooth reconstruction

### 📊 Multi-Viewport Comparison
- **Hanging protocols** (1×1, 1×2, 2×1, 2×2 grids)
- **Viewer linking** (scroll, window/level, zoom)
- **Keyboard shortcuts** for quick layout switching
- **Side-by-side comparison** for pre/post studies
- **Multi-modality** comparison support

### 🗄️ Database & Management
- **SQLite-based** DICOM index with GRDB
- **Fast queries** with optimized indices
- **Hierarchical navigation** (Patient → Study → Series → Instance)
- **DICOMDIR support** for CD/DVD import
- **Automatic indexing** with progress tracking

## Requirements

- **macOS 14.0** or later
- **Xcode 15.0** or later
- **Apple Silicon** or Intel Mac
- **Metal-capable GPU**

## Installation

### Building from Source

1. **Clone the repository:**
   ```bash
   git clone https://github.com/bchoi305/DicomVmac.git
   cd DicomVmac
   ```

2. **Install dependencies:**

   The project uses DCMTK for DICOM operations. Install via Homebrew:
   ```bash
   brew install dcmtk
   ```

3. **Open in Xcode:**
   ```bash
   open DicomVmac.xcodeproj
   ```

4. **Build and run:**
   - Select the DicomVmac scheme
   - Press ⌘R to build and run

## Usage

### Getting Started

1. **Index DICOM files:**
   - File → Index Folder... (⌘O)
   - Select a folder containing DICOM files
   - Wait for indexing to complete

2. **Browse and view:**
   - Navigate the hierarchy in the sidebar
   - Select a series to view images
   - Use scroll wheel or arrow keys to navigate slices

### PACS Integration

1. **Configure PACS server:**
   - Network → PACS Nodes...
   - Add new node with AE Title, hostname, and port
   - Test connection with C-ECHO

2. **Query and retrieve:**
   - Network → Query/Retrieve... (⌘F)
   - Enter search criteria
   - Select study and click Retrieve

### Export Images

- File → Export... (⌘E)
- Select format (JPEG/PNG/TIFF)
- Choose window/level preset
- Configure naming and scope
- Export to selected directory

### Anonymize Studies

- File → Anonymize...
- Select anonymization profile
- Configure patient ID mapping
- Set date shift strategy
- Process and save to output directory

### Multi-Planar Reconstruction

- Right-click series in sidebar
- Select "Open in MPR"
- Navigate orthogonal planes with synchronized views

## Architecture

### Technology Stack

- **Swift 5.9** - Primary application language
- **AppKit** - macOS UI framework
- **Metal** - GPU-accelerated rendering
- **DCMTK** - DICOM toolkit (C++)
- **GRDB** - SQLite database wrapper
- **Swift Testing** - Modern testing framework

### Project Structure

```
DicomVmac/
├── App/              # Application lifecycle and main window
├── Models/           # Data models (Patient, Study, Series, etc.)
├── Views/            # View controllers and UI components
├── Services/         # Business logic (networking, export, anonymization)
├── Renderer/         # Metal rendering pipeline
├── Bridge/           # Swift/C++ bridging layer
├── Database/         # Database manager and migrations
└── DicomCore/        # C++ DICOM processing (DCMTK wrapper)
    ├── include/      # Public C headers
    └── src/          # C++ implementations
```

### Key Components

- **MetalRenderer** - GPU-accelerated image rendering with window/level
- **DicomBridgeWrapper** - Async Swift interface to DCMTK
- **DatabaseManager** - Thread-safe SQLite operations
- **DicomNetworkService** - PACS operations (C-ECHO/FIND/MOVE/STORE)
- **MPRRenderer** - 3D volume reconstruction with trilinear interpolation
- **ViewerGridViewController** - Multi-viewport layout manager

## Testing

Run all tests:
```bash
xcodebuild test -project DicomVmac.xcodeproj -scheme DicomVmac -destination 'platform=macOS'
```

Current test coverage: **61 tests** across 10 suites including:
- Database operations
- DICOM tag extraction
- Frame caching
- Measurement calculations
- MPR functionality
- Network node validation
- Anonymization profiles

## Privacy & Security

- **Local-first** - All data stored locally in SQLite
- **No telemetry** - No usage tracking or analytics
- **HIPAA/GDPR** - Anonymization follows compliance standards
- **Secure networking** - DICOM TLS support (optional)

## Performance

- **60 FPS** rendering with Metal GPU acceleration
- **Instant navigation** with multi-threaded frame caching
- **Large volumes** efficiently handled (tested with 1000+ slice series)
- **Minimal memory** footprint with smart texture management
- **Asynchronous operations** prevent UI blocking

## Roadmap

- [ ] 3D Volume Rendering (VR/MIP/MinIP)
- [ ] Advanced measurements (ROI, histogram)
- [ ] Report generation with findings
- [ ] Cloud PACS integration
- [ ] DICOM SR (Structured Reports) support
- [ ] Multi-frame DICOM support (cine loops)

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- **DCMTK** - DICOM toolkit by OFFIS e.V.
- **GRDB** - SQLite wrapper by Gwendal Roué
- **Metal** - Apple's GPU framework

## Contact

- **Repository:** https://github.com/bchoi305/DicomVmac
- **Issues:** https://github.com/bchoi305/DicomVmac/issues

---

**Note:** This software is intended for research and educational purposes. Always verify results with certified medical imaging software before clinical use.

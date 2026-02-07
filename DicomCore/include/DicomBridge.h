//
//  DicomBridge.h
//  DicomCore
//
//  Public C ABI for the DICOM service layer.
//  Swift calls these functions via the bridging header.
//  Implementation is in C++ but the interface is pure C.
//

#ifndef DICOM_BRIDGE_H
#define DICOM_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Status codes ---
typedef enum {
    DB_STATUS_OK = 0,
    DB_STATUS_ERROR = -1,
    DB_STATUS_NOT_FOUND = -2,
    DB_STATUS_CANCELLED = -3,
    DB_STATUS_TIMEOUT = -4
} DB_Status;

// --- Opaque handles ---
typedef struct DB_Context DB_Context;

// --- Frame data for pixel transfer ---
typedef struct {
    uint16_t* pixels;       // Caller must free with db_free_buffer
    uint32_t  width;
    uint32_t  height;
    uint32_t  bitsStored;
    int32_t   rescaleSlope;
    int32_t   rescaleIntercept;
    double    windowCenter;
    double    windowWidth;
    double    pixelSpacingX;    // mm per pixel (column direction), 0 if unknown
    double    pixelSpacingY;    // mm per pixel (row direction), 0 if unknown
    int       hasPixelSpacing;  // 1 if PixelSpacing tag was present
    double    imagePositionZ;   // Z component of ImagePositionPatient
    double    sliceThickness;   // SliceThickness tag value
    int       hasImagePosition; // 1 if ImagePositionPatient was present
} DB_Frame16;

// --- Lifecycle ---
DB_Context* db_create(void);
void        db_destroy(DB_Context* ctx);

// --- Version / health ---
const char* db_version(void);

// --- Local file operations ---
DB_Status   db_decode_frame16(const char* filepath,
                              int frameIndex,
                              DB_Frame16* outFrame);

// --- Memory management ---
void        db_free_buffer(void* ptr);

// --- Tag extraction (no pixel decode) ---
typedef struct {
    char patientID[64];
    char patientName[128];
    char birthDate[16];
    char studyInstanceUID[128];
    char studyDate[16];
    char studyDescription[256];
    char accessionNumber[64];
    char studyModality[16];
    char seriesInstanceUID[128];
    int  seriesNumber;
    char seriesDescription[256];
    char seriesModality[16];
    char sopInstanceUID[128];
    int  instanceNumber;
    int  rows;
    int  columns;
    int  bitsAllocated;
} DB_DicomTags;

/// Extract DICOM tags from a single file (no pixel decode).
DB_Status db_extract_tags(const char* filepath, DB_DicomTags* outTags);

/// Callback invoked for each DICOM file found during folder scan.
typedef void (*DB_ScanCallback)(void* userData, const DB_DicomTags* tags,
                                const char* filePath);

/// Callback invoked periodically to report scan progress.
typedef void (*DB_ScanProgressCallback)(void* userData, int filesScanned,
                                        int filesFound);

/// Scan a folder recursively, calling callback for each DICOM file found.
DB_Status db_scan_folder(const char* folderPath,
                         DB_ScanCallback onFile,
                         DB_ScanProgressCallback onProgress,
                         void* userData);

// --- DICOMDIR support ---

/// Callback invoked for each DICOM file referenced in DICOMDIR.
typedef void (*DB_DicomdirFileCallback)(void* userData,
                                         const DB_DicomTags* tags,
                                         const char* filePath);

/// Callback for DICOMDIR scan progress.
typedef void (*DB_DicomdirProgressCallback)(void* userData,
                                             int recordsProcessed,
                                             int filesFound);

/// Scan a DICOMDIR file and invoke callback for each referenced image.
/// - dicomdirPath: Path to the DICOMDIR file
/// - onFile: Called for each valid DICOM file with extracted tags
/// - onProgress: Called periodically with progress info
/// - userData: User context passed to callbacks
/// Returns DB_STATUS_OK on success.
DB_Status db_scan_dicomdir(const char* dicomdirPath,
                            DB_DicomdirFileCallback onFile,
                            DB_DicomdirProgressCallback onProgress,
                            void* userData);

/// Check if a path points to a DICOMDIR file (or folder containing one).
/// Returns 1 if DICOMDIR, 0 otherwise.
int db_is_dicomdir(const char* path);

// --- DICOM Networking ---

/// Network operation result
typedef struct {
    DB_Status status;           // Operation status
    char errorMessage[256];     // Human-readable error message
    int dimseStatus;            // DIMSE status code (0 = success)
} DB_NetworkResult;

/// DICOM node (PACS server) configuration
typedef struct {
    char aeTitle[17];           // Application Entity Title (max 16 chars + null)
    char hostname[256];         // Hostname or IP address
    int port;                   // Port number (typically 104)
} DB_DicomNode;

/// Query callback invoked for each C-FIND response
typedef void (*DB_QueryCallback)(void* userData, const DB_DicomTags* tags);

/// Progress callback for C-MOVE and C-STORE operations
typedef void (*DB_MoveProgressCallback)(void* userData,
                                        int completed,
                                        int remaining,
                                        int failed);

/// Test connectivity to PACS server (C-ECHO)
/// - localAE: Local Application Entity Title
/// - remoteNode: Remote PACS node configuration
/// - timeoutSeconds: Operation timeout
/// Returns result with DIMSE status code
DB_NetworkResult db_echo(const char* localAE,
                         const DB_DicomNode* remoteNode,
                         int timeoutSeconds);

/// Query PACS for studies (C-FIND at STUDY level)
/// - localAE: Local Application Entity Title
/// - remoteNode: Remote PACS node configuration
/// - searchCriteria: DICOM tags to use as search criteria (NULL fields are wildcards)
/// - onResult: Callback invoked for each matching study
/// - userData: User context passed to callback
/// - timeoutSeconds: Operation timeout
/// Returns result with total matches found
DB_NetworkResult db_find_studies(const char* localAE,
                                  const DB_DicomNode* remoteNode,
                                  const DB_DicomTags* searchCriteria,
                                  DB_QueryCallback onResult,
                                  void* userData,
                                  int timeoutSeconds);

/// Retrieve study from PACS (C-MOVE)
/// - localAE: Local Application Entity Title (also used as move destination)
/// - remoteNode: Remote PACS node configuration
/// - studyInstanceUID: Study to retrieve
/// - destinationFolder: Local folder to store retrieved files
/// - onProgress: Callback for progress updates
/// - userData: User context passed to callback
/// - timeoutSeconds: Operation timeout
/// Returns result with transfer statistics
DB_NetworkResult db_move_study(const char* localAE,
                                const DB_DicomNode* remoteNode,
                                const char* studyInstanceUID,
                                const char* destinationFolder,
                                DB_MoveProgressCallback onProgress,
                                void* userData,
                                int timeoutSeconds);

/// Send study to PACS (C-STORE)
/// - localAE: Local Application Entity Title
/// - remoteNode: Remote PACS node configuration
/// - filePaths: Array of DICOM file paths to send
/// - fileCount: Number of files in array
/// - onProgress: Callback for progress updates
/// - userData: User context passed to callback
/// - timeoutSeconds: Operation timeout
/// Returns result with transfer statistics
DB_NetworkResult db_store_study(const char* localAE,
                                 const DB_DicomNode* remoteNode,
                                 const char* const* filePaths,
                                 int fileCount,
                                 DB_MoveProgressCallback onProgress,
                                 void* userData,
                                 int timeoutSeconds);

// ============================================================================
// ANONYMIZATION FUNCTIONS
// ============================================================================

/// Action to perform on a DICOM tag
typedef enum {
    DB_TAG_ACTION_REMOVE = 0,      // Remove tag entirely
    DB_TAG_ACTION_REPLACE = 1,     // Replace with specified value
    DB_TAG_ACTION_HASH = 2,        // Replace with hash of original
    DB_TAG_ACTION_EMPTY = 3,       // Replace with empty string
    DB_TAG_ACTION_KEEP = 4,        // Keep original value
    DB_TAG_ACTION_GENERATE_UID = 5 // Generate new UID
} DB_TagAction;

/// Rule for anonymizing a specific DICOM tag
typedef struct {
    unsigned short group;      // DICOM tag group (e.g., 0x0010)
    unsigned short element;    // DICOM tag element (e.g., 0x0010)
    DB_TagAction action;       // Action to perform
    char replacementValue[256]; // Used when action is REPLACE
} DB_TagRule;

/// Anonymization configuration
typedef struct {
    DB_TagRule* tagRules;      // Array of tag rules
    int tagRuleCount;          // Number of rules in array
    bool removePrivateTags;    // Remove all private tags
    bool replaceStudyUID;      // Replace Study Instance UID
    bool replaceSeriesUID;     // Replace Series Instance UID
    bool replaceSOPUID;        // Replace SOP Instance UID
    int dateShiftDays;         // Number of days to shift dates (0 = no shift, -1 = remove dates)
} DB_AnonymizationConfig;

/// Anonymize a DICOM file
/// - inputPath: Path to original DICOM file
/// - outputPath: Path for anonymized output file
/// - config: Anonymization configuration
/// Returns DB_STATUS_OK on success, error code otherwise
DB_Status db_anonymize_file(const char* inputPath,
                             const char* outputPath,
                             const DB_AnonymizationConfig* config);

/// Anonymize a DICOM file in-place
/// - filePath: Path to DICOM file to anonymize
/// - config: Anonymization configuration
/// Returns DB_STATUS_OK on success, error code otherwise
DB_Status db_anonymize_file_inplace(const char* filePath,
                                     const DB_AnonymizationConfig* config);

/// Generate a hash string for patient ID mapping
/// - input: Original value to hash
/// - output: Buffer to store hash (must be at least 65 bytes)
/// - outputSize: Size of output buffer
void db_generate_hash(const char* input,
                      char* output,
                      size_t outputSize);

#ifdef __cplusplus
}
#endif

#endif /* DICOM_BRIDGE_H */

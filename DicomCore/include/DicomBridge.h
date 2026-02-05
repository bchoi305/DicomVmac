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

#ifdef __cplusplus
}
#endif

#endif /* DICOM_BRIDGE_H */

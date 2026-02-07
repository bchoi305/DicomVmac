//
//  DicomBridge.cpp
//  DicomCore
//
//  C ABI implementation. Uses DCMTK for DICOM file decoding.
//

#include "DicomBridge.h"
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <algorithm>

#include "dcmtk/dcmdata/dctk.h"
#include "dcmtk/dcmimgle/dcmimage.h"
#include "dcmtk/dcmdata/dcdicdir.h"
#include "dcmtk/dcmdata/dcdirrec.h"

namespace fs = std::filesystem;

struct DB_Context {
    int initialized;
};

DB_Context* db_create(void) {
    auto* ctx = new DB_Context();
    ctx->initialized = 1;
    return ctx;
}

void db_destroy(DB_Context* ctx) {
    if (ctx) {
        delete ctx;
    }
}

const char* db_version(void) {
    return "DicomCore 0.1.0 (DCMTK " OFFIS_DCMTK_VERSION_STRING ")";
}

DB_Status db_decode_frame16(const char* filepath,
                            int frameIndex,
                            DB_Frame16* outFrame) {
    if (!outFrame) return DB_STATUS_ERROR;

    // If no filepath, return test pattern
    if (!filepath) {
        const uint32_t w = 256;
        const uint32_t h = 256;
        auto* pixels = (uint16_t*)calloc(w * h, sizeof(uint16_t));
        if (!pixels) return DB_STATUS_ERROR;

        for (uint32_t y = 0; y < h; y++) {
            for (uint32_t x = 0; x < w; x++) {
                pixels[y * w + x] = (uint16_t)((x + y) * 8);
            }
        }

        outFrame->pixels = pixels;
        outFrame->width = w;
        outFrame->height = h;
        outFrame->bitsStored = 12;
        outFrame->rescaleSlope = 1;
        outFrame->rescaleIntercept = -1024;
        outFrame->windowCenter = 40.0;
        outFrame->windowWidth = 400.0;
        outFrame->pixelSpacingX = 1.0;  // Test pattern: 1mm per pixel
        outFrame->pixelSpacingY = 1.0;
        outFrame->hasPixelSpacing = 1;
        outFrame->imagePositionZ = 0.0;
        outFrame->sliceThickness = 1.0;
        outFrame->hasImagePosition = 1;
        return DB_STATUS_OK;
    }

    // Load DICOM file with DCMTK
    DcmFileFormat fileFormat;
    OFCondition status = fileFormat.loadFile(filepath);
    if (status.bad()) {
        return DB_STATUS_NOT_FOUND;
    }

    DcmDataset* dataset = fileFormat.getDataset();
    if (!dataset) return DB_STATUS_ERROR;

    // Read image dimensions
    Uint16 rows = 0, cols = 0, bitsStored = 0, bitsAllocated = 0;
    dataset->findAndGetUint16(DCM_Rows, rows);
    dataset->findAndGetUint16(DCM_Columns, cols);
    dataset->findAndGetUint16(DCM_BitsStored, bitsStored);
    dataset->findAndGetUint16(DCM_BitsAllocated, bitsAllocated);

    if (rows == 0 || cols == 0) return DB_STATUS_ERROR;

    // Read rescale parameters
    Float64 rescaleSlope = 1.0, rescaleIntercept = 0.0;
    dataset->findAndGetFloat64(DCM_RescaleSlope, rescaleSlope);
    dataset->findAndGetFloat64(DCM_RescaleIntercept, rescaleIntercept);

    // Read window center/width
    Float64 windowCenter = 0.0, windowWidth = 0.0;
    dataset->findAndGetFloat64(DCM_WindowCenter, windowCenter);
    dataset->findAndGetFloat64(DCM_WindowWidth, windowWidth);

    // Read PixelSpacing (row spacing, column spacing in mm)
    // PixelSpacing format: "rowSpacing\columnSpacing" or two separate values
    Float64 pixelSpacingY = 0.0, pixelSpacingX = 0.0;
    int hasPixelSpacing = 0;
    OFCondition psStatus = dataset->findAndGetFloat64(DCM_PixelSpacing, pixelSpacingY, 0);
    if (psStatus.good()) {
        dataset->findAndGetFloat64(DCM_PixelSpacing, pixelSpacingX, 1);
        hasPixelSpacing = 1;
    }

    // Read ImagePositionPatient (format: "x\y\z") for slice Z position
    Float64 imagePositionZ = 0.0;
    int hasImagePosition = 0;
    const char* ippStr = nullptr;
    if (dataset->findAndGetString(DCM_ImagePositionPatient, ippStr).good() && ippStr) {
        // Parse "x\y\z" format - extract Z component (third value)
        Float64 x = 0, y = 0, z = 0;
        if (sscanf(ippStr, "%lf\\%lf\\%lf", &x, &y, &z) == 3) {
            imagePositionZ = z;
            hasImagePosition = 1;
        }
    }

    // Read SliceThickness as fallback for slice spacing
    Float64 sliceThickness = 0.0;
    dataset->findAndGetFloat64(DCM_SliceThickness, sliceThickness);

    // Use DicomImage for pixel access (handles photometric interpretation)
    DicomImage image(&fileFormat, dataset->getOriginalXfer(),
                     CIF_UsePartialAccessToPixelData, (unsigned long)frameIndex, 1);

    if (image.getStatus() != EIS_Normal) {
        return DB_STATUS_ERROR;
    }

    const uint32_t w = (uint32_t)image.getWidth();
    const uint32_t h = (uint32_t)image.getHeight();

    // Get raw pixel data as 16-bit unsigned
    auto* pixels = (uint16_t*)calloc(w * h, sizeof(uint16_t));
    if (!pixels) return DB_STATUS_ERROR;

    const void* pixelData = image.getOutputData(16, frameIndex);
    if (pixelData) {
        memcpy(pixels, pixelData, w * h * sizeof(uint16_t));
    } else {
        // Fallback: read raw pixel data directly
        const Uint16* rawData = nullptr;
        unsigned long count = 0;
        OFCondition pixStatus = dataset->findAndGetUint16Array(DCM_PixelData, rawData, &count);
        if (pixStatus.good() && rawData && count > 0) {
            size_t frameSize = (size_t)w * h;
            size_t offset = (size_t)frameIndex * frameSize;
            if (offset + frameSize <= count) {
                memcpy(pixels, rawData + offset, frameSize * sizeof(uint16_t));
            }
        } else {
            free(pixels);
            return DB_STATUS_ERROR;
        }
    }

    outFrame->pixels = pixels;
    outFrame->width = w;
    outFrame->height = h;
    outFrame->bitsStored = (uint32_t)bitsStored;
    outFrame->rescaleSlope = (int32_t)rescaleSlope;
    outFrame->rescaleIntercept = (int32_t)rescaleIntercept;
    outFrame->windowCenter = windowCenter;
    outFrame->windowWidth = windowWidth;
    outFrame->pixelSpacingX = pixelSpacingX;
    outFrame->pixelSpacingY = pixelSpacingY;
    outFrame->hasPixelSpacing = hasPixelSpacing;
    outFrame->imagePositionZ = imagePositionZ;
    outFrame->sliceThickness = sliceThickness;
    outFrame->hasImagePosition = hasImagePosition;

    // If no window values in file, compute reasonable defaults
    if (outFrame->windowWidth <= 0.0) {
        double maxVal = (1 << bitsStored) - 1;
        outFrame->windowCenter = maxVal / 2.0 + rescaleIntercept;
        outFrame->windowWidth = maxVal;
    }

    return DB_STATUS_OK;
}

void db_free_buffer(void* ptr) {
    free(ptr);
}

// --- Helper: safely copy a DCMTK string tag into a fixed buffer ---
static void copyTag(DcmDataset* ds, const DcmTagKey& tag,
                    char* dest, size_t destSize) {
    const char* val = nullptr;
    if (ds->findAndGetString(tag, val).good() && val) {
        strncpy(dest, val, destSize - 1);
        dest[destSize - 1] = '\0';
    } else {
        dest[0] = '\0';
    }
}

DB_Status db_extract_tags(const char* filepath, DB_DicomTags* outTags) {
    if (!filepath || !outTags) return DB_STATUS_ERROR;
    memset(outTags, 0, sizeof(DB_DicomTags));

    DcmFileFormat fileFormat;
    OFCondition status = fileFormat.loadFile(filepath);
    if (status.bad()) return DB_STATUS_NOT_FOUND;

    DcmDataset* ds = fileFormat.getDataset();
    if (!ds) return DB_STATUS_ERROR;

    // Patient-level tags
    copyTag(ds, DCM_PatientID, outTags->patientID, sizeof(outTags->patientID));
    copyTag(ds, DCM_PatientName, outTags->patientName, sizeof(outTags->patientName));
    copyTag(ds, DCM_PatientBirthDate, outTags->birthDate, sizeof(outTags->birthDate));

    // Study-level tags
    copyTag(ds, DCM_StudyInstanceUID, outTags->studyInstanceUID,
            sizeof(outTags->studyInstanceUID));
    copyTag(ds, DCM_StudyDate, outTags->studyDate, sizeof(outTags->studyDate));
    copyTag(ds, DCM_StudyDescription, outTags->studyDescription,
            sizeof(outTags->studyDescription));
    copyTag(ds, DCM_AccessionNumber, outTags->accessionNumber,
            sizeof(outTags->accessionNumber));

    // Study modality (top-level Modality tag)
    copyTag(ds, DCM_Modality, outTags->studyModality, sizeof(outTags->studyModality));

    // Series-level tags
    copyTag(ds, DCM_SeriesInstanceUID, outTags->seriesInstanceUID,
            sizeof(outTags->seriesInstanceUID));
    copyTag(ds, DCM_SeriesDescription, outTags->seriesDescription,
            sizeof(outTags->seriesDescription));
    // Series modality is typically the same tag
    copyTag(ds, DCM_Modality, outTags->seriesModality, sizeof(outTags->seriesModality));

    Sint32 seriesNum = 0;
    if (ds->findAndGetSint32(DCM_SeriesNumber, seriesNum).good())
        outTags->seriesNumber = (int)seriesNum;

    // Instance-level tags
    copyTag(ds, DCM_SOPInstanceUID, outTags->sopInstanceUID,
            sizeof(outTags->sopInstanceUID));

    Sint32 instNum = 0;
    if (ds->findAndGetSint32(DCM_InstanceNumber, instNum).good())
        outTags->instanceNumber = (int)instNum;

    Uint16 rows = 0, cols = 0, bitsAlloc = 0;
    ds->findAndGetUint16(DCM_Rows, rows);
    ds->findAndGetUint16(DCM_Columns, cols);
    ds->findAndGetUint16(DCM_BitsAllocated, bitsAlloc);

    outTags->rows = (int)rows;
    outTags->columns = (int)cols;
    outTags->bitsAllocated = (int)bitsAlloc;

    return DB_STATUS_OK;
}

DB_Status db_scan_folder(const char* folderPath,
                         DB_ScanCallback onFile,
                         DB_ScanProgressCallback onProgress,
                         void* userData) {
    if (!folderPath || !onFile) return DB_STATUS_ERROR;

    std::error_code ec;
    if (!fs::is_directory(folderPath, ec)) return DB_STATUS_NOT_FOUND;

    int filesScanned = 0;
    int filesFound = 0;

    for (const auto& entry : fs::recursive_directory_iterator(
             folderPath, fs::directory_options::skip_permission_denied, ec)) {
        if (!entry.is_regular_file(ec)) continue;

        filesScanned++;

        // Try to extract tags — if it succeeds, it's a valid DICOM file
        DB_DicomTags tags;
        std::string path = entry.path().string();
        DB_Status tagStatus = db_extract_tags(path.c_str(), &tags);

        if (tagStatus == DB_STATUS_OK && tags.sopInstanceUID[0] != '\0') {
            filesFound++;
            onFile(userData, &tags, path.c_str());
        }

        // Report progress every 50 files
        if (onProgress && (filesScanned % 50 == 0)) {
            onProgress(userData, filesScanned, filesFound);
        }
    }

    // Final progress report
    if (onProgress) {
        onProgress(userData, filesScanned, filesFound);
    }

    return DB_STATUS_OK;
}

// --- DICOMDIR Support ---

// Helper: Recursively process DICOMDIR records
static void processDirectoryRecord(DcmDirectoryRecord* rec,
                                    const fs::path& dicomdirDir,
                                    DB_DicomdirFileCallback onFile,
                                    DB_DicomdirProgressCallback onProgress,
                                    void* userData,
                                    int& recordsProcessed,
                                    int& filesFound) {
    if (!rec) return;

    recordsProcessed++;

    // Only process IMAGE records
    if (rec->getRecordType() == ERT_Image) {
        // Get referenced file ID (backslash-separated path)
        const char* refFileID = nullptr;
        if (rec->findAndGetString(DCM_ReferencedFileID, refFileID).good() && refFileID) {
            // Convert DICOM path separators (\) to OS separators (/)
            std::string relativePath(refFileID);
            std::replace(relativePath.begin(), relativePath.end(), '\\', '/');

            // Build absolute path relative to DICOMDIR location
            fs::path absPath = dicomdirDir / relativePath;
            std::string absPathStr = absPath.string();

            // Extract tags from the actual DICOM file
            DB_DicomTags tags;
            if (db_extract_tags(absPathStr.c_str(), &tags) == DB_STATUS_OK) {
                filesFound++;
                onFile(userData, &tags, absPathStr.c_str());
            }
        }
    }

    // Report progress every 20 records
    if (onProgress && (recordsProcessed % 20 == 0)) {
        onProgress(userData, recordsProcessed, filesFound);
    }

    // Recurse into child records
    unsigned long numChildren = rec->cardSub();
    for (unsigned long i = 0; i < numChildren; i++) {
        DcmDirectoryRecord* child = rec->getSub(i);
        processDirectoryRecord(child, dicomdirDir, onFile, onProgress,
                               userData, recordsProcessed, filesFound);
    }
}

DB_Status db_scan_dicomdir(const char* dicomdirPath,
                            DB_DicomdirFileCallback onFile,
                            DB_DicomdirProgressCallback onProgress,
                            void* userData) {
    if (!dicomdirPath || !onFile) return DB_STATUS_ERROR;

    std::error_code ec;
    fs::path dicomdirFile(dicomdirPath);

    // If path is a directory, look for DICOMDIR file inside
    if (fs::is_directory(dicomdirFile, ec)) {
        dicomdirFile = dicomdirFile / "DICOMDIR";
        if (!fs::exists(dicomdirFile, ec)) {
            return DB_STATUS_NOT_FOUND;
        }
    }

    if (!fs::exists(dicomdirFile, ec)) {
        return DB_STATUS_NOT_FOUND;
    }

    // Get the directory containing the DICOMDIR
    fs::path dicomdirDir = dicomdirFile.parent_path();

    // Load DICOMDIR using DCMTK
    DcmDicomDir dicomdir(dicomdirFile.string().c_str());
    if (dicomdir.error().bad()) {
        return DB_STATUS_ERROR;
    }

    // Get root record and traverse hierarchy
    DcmDirectoryRecord& rootRec = dicomdir.getRootRecord();
    int recordsProcessed = 0;
    int filesFound = 0;

    unsigned long numChildren = rootRec.cardSub();
    for (unsigned long i = 0; i < numChildren; i++) {
        DcmDirectoryRecord* child = rootRec.getSub(i);
        processDirectoryRecord(child, dicomdirDir, onFile, onProgress,
                               userData, recordsProcessed, filesFound);
    }

    // Final progress callback
    if (onProgress) {
        onProgress(userData, recordsProcessed, filesFound);
    }

    return DB_STATUS_OK;
}

int db_is_dicomdir(const char* path) {
    if (!path) return 0;

    std::error_code ec;
    fs::path p(path);

    // If it's a file, check if it's named DICOMDIR
    if (fs::is_regular_file(p, ec)) {
        std::string filename = p.filename().string();
        // Convert to uppercase for case-insensitive comparison
        std::transform(filename.begin(), filename.end(), filename.begin(), ::toupper);
        if (filename == "DICOMDIR") {
            // Verify it's a valid DICOMDIR
            DcmDicomDir dicomdir(path);
            return dicomdir.error().good() ? 1 : 0;
        }
        return 0;
    }

    // If it's a directory, check for DICOMDIR file inside
    if (fs::is_directory(p, ec)) {
        fs::path dicomdirFile = p / "DICOMDIR";
        if (fs::exists(dicomdirFile, ec)) {
            DcmDicomDir dicomdir(dicomdirFile.string().c_str());
            return dicomdir.error().good() ? 1 : 0;
        }
    }

    return 0;
}

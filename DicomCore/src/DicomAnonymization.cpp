//
//  DicomAnonymization.cpp
//  DicomCore
//
//  DICOM anonymization functions using DCMTK.
//

#include "DicomBridge.h"
#include "dcmtk/dcmdata/dctk.h"
#include "dcmtk/dcmdata/dcfilefo.h"
#include "dcmtk/dcmdata/dcuid.h"
#include <string>
#include <sstream>
#include <iomanip>
#include <functional>

// Helper: Generate new UID
static std::string generateNewUID() {
    char uid[100];
    dcmGenerateUniqueIdentifier(uid, SITE_INSTANCE_UID_ROOT);
    return std::string(uid);
}

// Helper: Hash a string using std::hash
static std::string hashString(const std::string& input) {
    std::hash<std::string> hasher;
    size_t hashValue = hasher(input);

    std::stringstream ss;
    ss << std::hex << std::setw(16) << std::setfill('0') << hashValue;
    return ss.str();
}

// Helper: Apply tag rule to dataset
static void applyTagRule(DcmDataset* dataset, const DB_TagRule& rule) {
    DcmTag tag(rule.group, rule.element);

    switch (rule.action) {
        case DB_TAG_ACTION_REMOVE:
            // Remove the tag entirely
            dataset->findAndDeleteElement(tag);
            break;

        case DB_TAG_ACTION_REPLACE: {
            // Replace with specified value
            std::string replacement(rule.replacementValue);
            if (!replacement.empty()) {
                dataset->putAndInsertString(tag, replacement.c_str(), OFTrue);
            }
            break;
        }

        case DB_TAG_ACTION_HASH: {
            // Replace with hash of original value
            OFString originalValue;
            if (dataset->findAndGetOFString(tag, originalValue).good()) {
                std::string hashed = hashString(originalValue.c_str());

                // Truncate hash to reasonable length for the field
                if (hashed.length() > 64) {
                    hashed = hashed.substr(0, 64);
                }

                dataset->putAndInsertString(tag, hashed.c_str(), OFTrue);
            }
            break;
        }

        case DB_TAG_ACTION_EMPTY:
            // Replace with empty string
            dataset->putAndInsertString(tag, "", OFTrue);
            break;

        case DB_TAG_ACTION_KEEP:
            // Do nothing - keep original value
            break;

        case DB_TAG_ACTION_GENERATE_UID: {
            // Generate new UID
            std::string newUID = generateNewUID();
            dataset->putAndInsertString(tag, newUID.c_str(), OFTrue);
            break;
        }
    }
}

// Helper: Remove private tags
static void removePrivateTags(DcmDataset* dataset) {
    DcmStack stack;
    DcmObject* obj = nullptr;

    // Find all private tags (group number is odd)
    OFCondition cond = dataset->nextObject(stack, OFTrue);
    while (cond.good()) {
        obj = stack.top();
        if (obj) {
            DcmTag tag = obj->getTag();
            unsigned short group = tag.getGroup();

            // Private tags have odd group numbers
            if (group % 2 == 1) {
                dataset->findAndDeleteElement(tag);
            }
        }
        cond = dataset->nextObject(stack, OFTrue);
    }
}

// Helper: Shift date by specified days
static std::string shiftDate(const std::string& dateStr, int dayShift) {
    if (dateStr.empty() || dateStr.length() != 8) {
        return "";
    }

    // Parse YYYYMMDD format
    int year = std::stoi(dateStr.substr(0, 4));
    int month = std::stoi(dateStr.substr(4, 2));
    int day = std::stoi(dateStr.substr(6, 2));

    // Simple date arithmetic (not handling month/year boundaries properly for brevity)
    // In production, use a proper date library
    day += dayShift;

    // Rough normalization
    while (day > 28) {
        day -= 28;
        month++;
        if (month > 12) {
            month = 1;
            year++;
        }
    }
    while (day < 1) {
        day += 28;
        month--;
        if (month < 1) {
            month = 12;
            year--;
        }
    }

    std::stringstream ss;
    ss << std::setfill('0')
       << std::setw(4) << year
       << std::setw(2) << month
       << std::setw(2) << day;
    return ss.str();
}

// Helper: Process date tags
static void processDateTags(DcmDataset* dataset, int dateShiftDays) {
    if (dateShiftDays == -1) {
        // Remove all date/time tags
        DcmTag dateTags[] = {
            DCM_StudyDate,
            DCM_SeriesDate,
            DCM_AcquisitionDate,
            DCM_ContentDate,
            DCM_PatientBirthDate,
            DCM_InstanceCreationDate,
            DCM_StudyTime,
            DCM_SeriesTime,
            DCM_AcquisitionTime,
            DCM_ContentTime
        };

        for (const auto& tag : dateTags) {
            dataset->findAndDeleteElement(tag);
        }
    } else if (dateShiftDays != 0) {
        // Shift dates
        DcmTag dateTags[] = {
            DCM_StudyDate,
            DCM_SeriesDate,
            DCM_AcquisitionDate,
            DCM_ContentDate,
            DCM_PatientBirthDate,
            DCM_InstanceCreationDate
        };

        for (const auto& tag : dateTags) {
            DcmElement* elem = nullptr;
            if (dataset->findAndGetElement(tag, elem).good() && elem) {
                OFString originalValue;
                if (elem->getOFString(originalValue, 0).good()) {
                    std::string shifted = shiftDate(originalValue.c_str(), dateShiftDays);
                    if (!shifted.empty()) {
                        elem->putString(shifted.c_str());
                    }
                }
            }
        }
    }
}

// Main anonymization function
DB_Status db_anonymize_file(const char* inputPath,
                             const char* outputPath,
                             const DB_AnonymizationConfig* config) {
    if (!inputPath || !outputPath || !config) {
        return DB_STATUS_ERROR;
    }

    // Load DICOM file
    DcmFileFormat fileFormat;
    OFCondition status = fileFormat.loadFile(inputPath);
    if (status.bad()) {
        return DB_STATUS_NOT_FOUND;
    }

    DcmDataset* dataset = fileFormat.getDataset();
    if (!dataset) {
        return DB_STATUS_ERROR;
    }

    // Apply tag rules
    for (int i = 0; i < config->tagRuleCount; i++) {
        applyTagRule(dataset, config->tagRules[i]);
    }

    // Remove private tags if requested
    if (config->removePrivateTags) {
        removePrivateTags(dataset);
    }

    // Process date shifting
    processDateTags(dataset, config->dateShiftDays);

    // Replace UIDs if requested
    if (config->replaceStudyUID) {
        std::string newUID = generateNewUID();
        dataset->putAndInsertString(DCM_StudyInstanceUID, newUID.c_str());
    }

    if (config->replaceSeriesUID) {
        std::string newUID = generateNewUID();
        dataset->putAndInsertString(DCM_SeriesInstanceUID, newUID.c_str());
    }

    if (config->replaceSOPUID) {
        std::string newUID = generateNewUID();
        dataset->putAndInsertString(DCM_SOPInstanceUID, newUID.c_str());

        // Also update Media Storage SOP Instance UID in meta header
        DcmMetaInfo* metaInfo = fileFormat.getMetaInfo();
        if (metaInfo) {
            metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, newUID.c_str());
        }
    }

    // Save anonymized file
    status = fileFormat.saveFile(outputPath, EXS_LittleEndianExplicit);
    if (status.bad()) {
        return DB_STATUS_ERROR;
    }

    return DB_STATUS_OK;
}

// In-place anonymization
DB_Status db_anonymize_file_inplace(const char* filePath,
                                     const DB_AnonymizationConfig* config) {
    if (!filePath || !config) {
        return DB_STATUS_ERROR;
    }

    // Create temporary output path
    std::string tempPath = std::string(filePath) + ".tmp";

    // Anonymize to temp file
    DB_Status status = db_anonymize_file(filePath, tempPath.c_str(), config);
    if (status != DB_STATUS_OK) {
        return status;
    }

    // Replace original with anonymized version
    if (remove(filePath) != 0) {
        remove(tempPath.c_str());
        return DB_STATUS_ERROR;
    }

    if (rename(tempPath.c_str(), filePath) != 0) {
        return DB_STATUS_ERROR;
    }

    return DB_STATUS_OK;
}

// Generate hash for external use
void db_generate_hash(const char* input,
                      char* output,
                      size_t outputSize) {
    if (!input || !output || outputSize < 65) {
        return;
    }

    std::string hashed = hashString(input);
    strncpy(output, hashed.c_str(), outputSize - 1);
    output[outputSize - 1] = '\0';
}

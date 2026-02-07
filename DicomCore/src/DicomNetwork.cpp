//
//  DicomNetwork.cpp
//  DicomCore
//
//  DICOM networking operations using DCMTK.
//  Implements C-ECHO, C-FIND, C-MOVE, and C-STORE.
//

#include "DicomBridge.h"
#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmnet/dimse.h"
#include "dcmtk/dcmnet/assoc.h"
#include "dcmtk/dcmnet/diutil.h"
#include "dcmtk/dcmdata/dcdeftag.h"
#include "dcmtk/dcmdata/dcfilefo.h"
#include "dcmtk/dcmdata/dcistrmb.h"
#include "dcmtk/ofstd/ofstd.h"
#include <cstring>
#include <cstdio>

// --- Helper: Initialize result ---
static DB_NetworkResult makeResult(DB_Status status, const char* message = "", int dimseStatus = 0) {
    DB_NetworkResult result;
    result.status = status;
    result.dimseStatus = dimseStatus;
    strncpy(result.errorMessage, message, sizeof(result.errorMessage) - 1);
    result.errorMessage[sizeof(result.errorMessage) - 1] = '\0';
    return result;
}

// --- Helper: Convert OFCondition to DB_NetworkResult ---
static DB_NetworkResult conditionToResult(const OFCondition& cond, const char* operation) {
    if (cond.good()) {
        return makeResult(DB_STATUS_OK);
    }

    char msg[256];
    snprintf(msg, sizeof(msg), "%s failed: %s", operation, cond.text());
    return makeResult(DB_STATUS_ERROR, msg);
}

// --- Helper: Create association ---
static OFCondition createAssociation(
    const char* localAE,
    const DB_DicomNode* remoteNode,
    const char* abstractSyntax,
    T_ASC_Network*& net,
    T_ASC_Association*& assoc,
    int timeoutSeconds)
{
    OFCondition cond;

    // Initialize network
    cond = ASC_initializeNetwork(NET_REQUESTOR, 0, timeoutSeconds, &net);
    if (cond.bad()) return cond;

    // Create association parameters
    T_ASC_Parameters* params = nullptr;
    cond = ASC_createAssociationParameters(&params, ASC_DEFAULTMAXPDU);
    if (cond.bad()) {
        ASC_dropNetwork(&net);
        return cond;
    }

    // Set application entity titles
    ASC_setAPTitles(params, localAE, remoteNode->aeTitle, nullptr);

    // Set peer hostname
    char peerHost[256];
    snprintf(peerHost, sizeof(peerHost), "%s:%d", remoteNode->hostname, remoteNode->port);
    ASC_setPresentationAddresses(params, "localhost", peerHost);

    // Add presentation context
    const char* transferSyntaxes[] = {
        UID_LittleEndianImplicitTransferSyntax,
        UID_LittleEndianExplicitTransferSyntax,
        UID_BigEndianExplicitTransferSyntax
    };

    cond = ASC_addPresentationContext(
        params, 1, abstractSyntax,
        transferSyntaxes, 3,
        ASC_SC_ROLE_DEFAULT);

    if (cond.bad()) {
        ASC_destroyAssociationParameters(&params);
        ASC_dropNetwork(&net);
        return cond;
    }

    // Request association
    cond = ASC_requestAssociation(net, params, &assoc);
    if (cond.bad()) {
        ASC_destroyAssociationParameters(&params);
        ASC_dropNetwork(&net);
        return cond;
    }

    // Check if presentation context was accepted
    if (ASC_findAcceptedPresentationContextID(assoc, abstractSyntax) == 0) {
        ASC_abortAssociation(assoc);
        ASC_dropAssociation(assoc);
        ASC_dropNetwork(&net);
        return makeOFCondition(0, 0, OF_error, "Presentation context rejected");
    }

    return EC_Normal;
}

// --- Helper: Release association ---
static void releaseAssociation(T_ASC_Association* assoc, T_ASC_Network* net) {
    if (assoc) {
        ASC_releaseAssociation(assoc);
        ASC_dropAssociation(assoc);
    }
    if (net) {
        ASC_dropNetwork(&net);
    }
}

// ========================================================================
// C-ECHO: Test connectivity
// ========================================================================

DB_NetworkResult db_echo(
    const char* localAE,
    const DB_DicomNode* remoteNode,
    int timeoutSeconds)
{
    if (!localAE || !remoteNode) {
        return makeResult(DB_STATUS_ERROR, "Invalid parameters");
    }

    T_ASC_Network* net = nullptr;
    T_ASC_Association* assoc = nullptr;

    // Create association
    OFCondition cond = createAssociation(
        localAE, remoteNode,
        UID_VerificationSOPClass,
        net, assoc, timeoutSeconds);

    if (cond.bad()) {
        return conditionToResult(cond, "Association");
    }

    // Send C-ECHO
    DIC_US msgId = assoc->nextMsgID++;
    DIC_US status = 0;

    cond = DIMSE_echoUser(
        assoc, msgId,
        DIMSE_BLOCKING, timeoutSeconds,
        &status, nullptr);

    DB_NetworkResult result;
    if (cond.bad()) {
        result = conditionToResult(cond, "C-ECHO");
    } else if (status != STATUS_Success) {
        char msg[128];
        snprintf(msg, sizeof(msg), "C-ECHO failed with DIMSE status 0x%04x", status);
        result = makeResult(DB_STATUS_ERROR, msg, status);
    } else {
        result = makeResult(DB_STATUS_OK, "C-ECHO successful", status);
    }

    // Release association
    releaseAssociation(assoc, net);

    return result;
}

// ========================================================================
// C-FIND: Query for studies
// ========================================================================

// Context for C-FIND callback
struct FindContext {
    DB_QueryCallback userCallback;
    void* userData;
    int matchCount;
};

static void findCallback(
    void* callbackData,
    T_DIMSE_C_FindRQ* /* request */,
    int responseCount,
    T_DIMSE_C_FindRSP* rsp,
    DcmDataset* responseIdentifiers)
{
    FindContext* ctx = static_cast<FindContext*>(callbackData);

    // Only process if we have identifiers and status is pending
    if (!responseIdentifiers || rsp->DimseStatus != STATUS_Pending) {
        return;
    }

    ctx->matchCount++;

    // Extract tags from response dataset
    DB_DicomTags tags;
    memset(&tags, 0, sizeof(tags));

    OFString str;

    // Patient level
    if (responseIdentifiers->findAndGetOFString(DCM_PatientID, str).good()) {
        strncpy(tags.patientID, str.c_str(), sizeof(tags.patientID) - 1);
    }
    if (responseIdentifiers->findAndGetOFString(DCM_PatientName, str).good()) {
        strncpy(tags.patientName, str.c_str(), sizeof(tags.patientName) - 1);
    }
    if (responseIdentifiers->findAndGetOFString(DCM_PatientBirthDate, str).good()) {
        strncpy(tags.birthDate, str.c_str(), sizeof(tags.birthDate) - 1);
    }

    // Study level
    if (responseIdentifiers->findAndGetOFString(DCM_StudyInstanceUID, str).good()) {
        strncpy(tags.studyInstanceUID, str.c_str(), sizeof(tags.studyInstanceUID) - 1);
    }
    if (responseIdentifiers->findAndGetOFString(DCM_StudyDate, str).good()) {
        strncpy(tags.studyDate, str.c_str(), sizeof(tags.studyDate) - 1);
    }
    if (responseIdentifiers->findAndGetOFString(DCM_StudyDescription, str).good()) {
        strncpy(tags.studyDescription, str.c_str(), sizeof(tags.studyDescription) - 1);
    }
    if (responseIdentifiers->findAndGetOFString(DCM_AccessionNumber, str).good()) {
        strncpy(tags.accessionNumber, str.c_str(), sizeof(tags.accessionNumber) - 1);
    }
    if (responseIdentifiers->findAndGetOFString(DCM_ModalitiesInStudy, str).good()) {
        strncpy(tags.studyModality, str.c_str(), sizeof(tags.studyModality) - 1);
    }

    // Invoke user callback
    if (ctx->userCallback) {
        ctx->userCallback(ctx->userData, &tags);
    }
}

DB_NetworkResult db_find_studies(
    const char* localAE,
    const DB_DicomNode* remoteNode,
    const DB_DicomTags* searchCriteria,
    DB_QueryCallback onResult,
    void* userData,
    int timeoutSeconds)
{
    if (!localAE || !remoteNode || !searchCriteria) {
        return makeResult(DB_STATUS_ERROR, "Invalid parameters");
    }

    T_ASC_Network* net = nullptr;
    T_ASC_Association* assoc = nullptr;

    // Create association
    OFCondition cond = createAssociation(
        localAE, remoteNode,
        UID_FINDStudyRootQueryRetrieveInformationModel,
        net, assoc, timeoutSeconds);

    if (cond.bad()) {
        return conditionToResult(cond, "Association");
    }

    // Build C-FIND request dataset
    DcmDataset findRequest;

    // Query/Retrieve Level
    findRequest.putAndInsertString(DCM_QueryRetrieveLevel, "STUDY");

    // Search criteria (empty string = wildcard)
    if (searchCriteria->patientID[0]) {
        findRequest.putAndInsertString(DCM_PatientID, searchCriteria->patientID);
    } else {
        findRequest.putAndInsertString(DCM_PatientID, "");
    }

    if (searchCriteria->patientName[0]) {
        findRequest.putAndInsertString(DCM_PatientName, searchCriteria->patientName);
    } else {
        findRequest.putAndInsertString(DCM_PatientName, "");
    }

    if (searchCriteria->studyDate[0]) {
        findRequest.putAndInsertString(DCM_StudyDate, searchCriteria->studyDate);
    } else {
        findRequest.putAndInsertString(DCM_StudyDate, "");
    }

    if (searchCriteria->accessionNumber[0]) {
        findRequest.putAndInsertString(DCM_AccessionNumber, searchCriteria->accessionNumber);
    } else {
        findRequest.putAndInsertString(DCM_AccessionNumber, "");
    }

    if (searchCriteria->studyModality[0]) {
        findRequest.putAndInsertString(DCM_ModalitiesInStudy, searchCriteria->studyModality);
    } else {
        findRequest.putAndInsertString(DCM_ModalitiesInStudy, "");
    }

    // Return keys (what we want back)
    findRequest.putAndInsertString(DCM_StudyInstanceUID, "");
    findRequest.putAndInsertString(DCM_StudyDescription, "");
    findRequest.putAndInsertString(DCM_PatientBirthDate, "");

    // Setup callback context
    FindContext ctx;
    ctx.userCallback = onResult;
    ctx.userData = userData;
    ctx.matchCount = 0;

    // Send C-FIND
    T_ASC_PresentationContextID presID =
        ASC_findAcceptedPresentationContextID(assoc,
            UID_FINDStudyRootQueryRetrieveInformationModel);

    T_DIMSE_C_FindRQ request;
    memset(&request, 0, sizeof(request));
    request.MessageID = assoc->nextMsgID++;
    strcpy(request.AffectedSOPClassUID, UID_FINDStudyRootQueryRetrieveInformationModel);
    request.Priority = DIMSE_PRIORITY_LOW;
    request.DataSetType = DIMSE_DATASET_PRESENT;

    T_DIMSE_C_FindRSP response;
    DcmDataset* statusDetail = nullptr;
    int responseCount = 0;

    cond = DIMSE_findUser(
        assoc, presID, &request, &findRequest,
        responseCount,
        findCallback, &ctx,
        DIMSE_BLOCKING, timeoutSeconds,
        &response, &statusDetail);

    if (statusDetail) {
        delete statusDetail;
    }

    DB_NetworkResult result;
    if (cond.bad()) {
        result = conditionToResult(cond, "C-FIND");
    } else {
        char msg[128];
        snprintf(msg, sizeof(msg), "C-FIND completed, %d matches found", ctx.matchCount);
        result = makeResult(DB_STATUS_OK, msg, response.DimseStatus);
    }

    // Release association
    releaseAssociation(assoc, net);

    return result;
}

// ========================================================================
// C-MOVE: Retrieve study
// ========================================================================

// Context for C-MOVE callback
struct MoveContext {
    DB_MoveProgressCallback progressCallback;
    void* userData;
    const char* destinationFolder;
    int completed;
    int remaining;
    int failed;
};

static void moveCallback(
    void* callbackData,
    T_DIMSE_C_MoveRQ* /* request */,
    int /* responseCount */,
    T_DIMSE_C_MoveRSP* rsp)
{
    MoveContext* ctx = static_cast<MoveContext*>(callbackData);

    ctx->completed = rsp->NumberOfCompletedSubOperations;
    ctx->remaining = rsp->NumberOfRemainingSubOperations;
    ctx->failed = rsp->NumberOfFailedSubOperations;

    // Invoke user callback
    if (ctx->progressCallback) {
        ctx->progressCallback(ctx->userData, ctx->completed, ctx->remaining, ctx->failed);
    }
}

DB_NetworkResult db_move_study(
    const char* localAE,
    const DB_DicomNode* remoteNode,
    const char* studyInstanceUID,
    const char* destinationFolder,
    DB_MoveProgressCallback onProgress,
    void* userData,
    int timeoutSeconds)
{
    if (!localAE || !remoteNode || !studyInstanceUID || !destinationFolder) {
        return makeResult(DB_STATUS_ERROR, "Invalid parameters");
    }

    T_ASC_Network* net = nullptr;
    T_ASC_Association* assoc = nullptr;

    // Create association
    OFCondition cond = createAssociation(
        localAE, remoteNode,
        UID_MOVEStudyRootQueryRetrieveInformationModel,
        net, assoc, timeoutSeconds);

    if (cond.bad()) {
        return conditionToResult(cond, "Association");
    }

    // Build C-MOVE request dataset
    DcmDataset moveRequest;
    moveRequest.putAndInsertString(DCM_QueryRetrieveLevel, "STUDY");
    moveRequest.putAndInsertString(DCM_StudyInstanceUID, studyInstanceUID);

    // Setup callback context
    MoveContext ctx;
    ctx.progressCallback = onProgress;
    ctx.userData = userData;
    ctx.destinationFolder = destinationFolder;
    ctx.completed = 0;
    ctx.remaining = 0;
    ctx.failed = 0;

    // Send C-MOVE
    T_ASC_PresentationContextID presID =
        ASC_findAcceptedPresentationContextID(assoc,
            UID_MOVEStudyRootQueryRetrieveInformationModel);

    T_DIMSE_C_MoveRQ request;
    memset(&request, 0, sizeof(request));
    request.MessageID = assoc->nextMsgID++;
    strcpy(request.AffectedSOPClassUID, UID_MOVEStudyRootQueryRetrieveInformationModel);
    request.Priority = DIMSE_PRIORITY_LOW;
    request.DataSetType = DIMSE_DATASET_PRESENT;
    strncpy(request.MoveDestination, localAE, sizeof(request.MoveDestination) - 1);

    T_DIMSE_C_MoveRSP response;
    DcmDataset* statusDetail = nullptr;

    cond = DIMSE_moveUser(
        assoc, presID, &request, &moveRequest,
        moveCallback, &ctx,
        DIMSE_BLOCKING, timeoutSeconds,
        net, nullptr, nullptr,
        &response, &statusDetail, nullptr);

    if (statusDetail) {
        delete statusDetail;
    }

    DB_NetworkResult result;
    if (cond.bad()) {
        result = conditionToResult(cond, "C-MOVE");
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg),
                 "C-MOVE completed: %d succeeded, %d failed",
                 ctx.completed, ctx.failed);
        result = makeResult(DB_STATUS_OK, msg, response.DimseStatus);
    }

    // Release association
    releaseAssociation(assoc, net);

    return result;
}

// ========================================================================
// C-STORE: Send study
// ========================================================================

DB_NetworkResult db_store_study(
    const char* localAE,
    const DB_DicomNode* remoteNode,
    const char* const* filePaths,
    int fileCount,
    DB_MoveProgressCallback onProgress,
    void* userData,
    int timeoutSeconds)
{
    if (!localAE || !remoteNode || !filePaths || fileCount <= 0) {
        return makeResult(DB_STATUS_ERROR, "Invalid parameters");
    }

    T_ASC_Network* net = nullptr;
    T_ASC_Association* assoc = nullptr;

    // Note: For C-STORE we need to add multiple presentation contexts
    // (one for each SOP class we might send). This is a simplified version
    // that assumes all files are of compatible transfer syntaxes.

    OFCondition cond = createAssociation(
        localAE, remoteNode,
        UID_SecondaryCaptureImageStorage,  // Generic storage SOP class
        net, assoc, timeoutSeconds);

    if (cond.bad()) {
        return conditionToResult(cond, "Association");
    }

    int completed = 0;
    int failed = 0;

    // Send each file
    for (int i = 0; i < fileCount; i++) {
        DcmFileFormat fileFormat;
        cond = fileFormat.loadFile(filePaths[i]);

        if (cond.bad()) {
            failed++;
            continue;
        }

        DcmDataset* dataset = fileFormat.getDataset();

        // Get SOP Class UID and SOP Instance UID
        OFString sopClassUID;
        OFString sopInstanceUID;

        if (!dataset->findAndGetOFString(DCM_SOPClassUID, sopClassUID).good() ||
            !dataset->findAndGetOFString(DCM_SOPInstanceUID, sopInstanceUID).good()) {
            failed++;
            continue;
        }

        // Find presentation context for this SOP class
        T_ASC_PresentationContextID presID =
            ASC_findAcceptedPresentationContextID(assoc, sopClassUID.c_str());

        if (presID == 0) {
            failed++;
            continue;
        }

        // Send C-STORE
        T_DIMSE_C_StoreRQ request;
        memset(&request, 0, sizeof(request));
        request.MessageID = assoc->nextMsgID++;
        strcpy(request.AffectedSOPClassUID, sopClassUID.c_str());
        strcpy(request.AffectedSOPInstanceUID, sopInstanceUID.c_str());
        request.Priority = DIMSE_PRIORITY_LOW;
        request.DataSetType = DIMSE_DATASET_PRESENT;

        T_DIMSE_C_StoreRSP response;
        DcmDataset* statusDetail = nullptr;

        cond = DIMSE_storeUser(
            assoc, presID, &request, nullptr,
            dataset, nullptr, nullptr,
            DIMSE_BLOCKING, timeoutSeconds,
            &response, &statusDetail, nullptr);

        if (statusDetail) {
            delete statusDetail;
        }

        if (cond.good() && response.DimseStatus == STATUS_Success) {
            completed++;
        } else {
            failed++;
        }

        // Progress callback
        if (onProgress) {
            int remaining = fileCount - (completed + failed);
            onProgress(userData, completed, remaining, failed);
        }
    }

    DB_NetworkResult result;
    char msg[256];
    snprintf(msg, sizeof(msg),
             "C-STORE completed: %d succeeded, %d failed",
             completed, failed);
    result = makeResult(DB_STATUS_OK, msg);

    // Release association
    releaseAssociation(assoc, net);

    return result;
}

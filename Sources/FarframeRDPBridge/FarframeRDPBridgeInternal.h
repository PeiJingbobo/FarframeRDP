#ifndef FARFRAME_RDP_BRIDGE_INTERNAL_H
#define FARFRAME_RDP_BRIDGE_INTERNAL_H

#include "FarframeRDPBridge.h"

#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/freerdp.h>
#include <winpr/synch.h>

#include <pthread.h>
#include <stdatomic.h>

typedef enum FFRSessionState {
    FFR_SESSION_STATE_CREATED = 0,
    FFR_SESSION_STATE_CONFIGURED = 1,
    FFR_SESSION_STATE_CONNECTING = 2,
    FFR_SESSION_STATE_CONNECTED = 3,
    FFR_SESSION_STATE_FINISHED = 4
} FFRSessionState;

typedef struct FFRRdpContext {
    rdpContext base;
    struct FFRSession *session;
} FFRRdpContext;

typedef enum FFRQueuedInputType {
    FFR_QUEUED_INPUT_SCAN_CODE = 1,
    FFR_QUEUED_INPUT_UNICODE = 2,
    FFR_QUEUED_INPUT_POINTER_MOVE = 3,
    FFR_QUEUED_INPUT_POINTER_BUTTON = 4,
    FFR_QUEUED_INPUT_POINTER_WHEEL = 5,
    FFR_QUEUED_INPUT_SYNCHRONIZE = 6,
    FFR_QUEUED_INPUT_RELEASE_ALL = 7,
    FFR_QUEUED_INPUT_RESIZE = 8,
    FFR_QUEUED_INPUT_CLIPBOARD_OFFER = 9,
    FFR_QUEUED_INPUT_CLIPBOARD_REQUEST = 10,
    FFR_QUEUED_INPUT_CLIPBOARD_FILE_RESPONSE = 11,
    FFR_QUEUED_INPUT_CLIPBOARD_FILE_REQUEST = 12,
    FFR_QUEUED_INPUT_CLIPBOARD_LOCK = 13,
    FFR_QUEUED_INPUT_CLIPBOARD_UNLOCK = 14
} FFRQueuedInputType;

enum { FFR_MAX_MONITOR_LAYOUTS = 16 };

typedef struct FFRQueuedInput {
    FFRQueuedInputType type;
    uint32_t scanCode;
    uint16_t codeUnit;
    uint16_t x;
    uint16_t y;
    int16_t wheelDelta;
    FFRPointerButton button;
    bool down;
    bool repeat;
    bool horizontal;
    uint32_t toggleFlags;
    uint32_t width;
    uint32_t height;
    FFRMonitorLayout monitors[FFR_MAX_MONITOR_LAYOUTS];
    size_t monitorCount;
    uint64_t clipboardGeneration;
    uint32_t clipboardFormatId;
    FFRClipboardFormatKind clipboardFormat;
    uint64_t fileRequestId;
    uint32_t streamId;
    uint32_t fileListIndex;
    FFRClipboardFileRequestKind fileRequestKind;
    uint64_t fileOffset;
    uint32_t fileRequestedBytes;
} FFRQueuedInput;

enum {
    FFR_MAX_CLIPBOARD_FORMATS = 16,
    FFR_MAX_REMOTE_CLIPBOARD_FORMATS = 64,
    FFR_MAX_CLIPBOARD_FILE_REQUESTS = 16,
    FFR_MAX_CLIPBOARD_FILE_RANGE_BYTES = 1024 * 1024
};

typedef struct FFRStoredClipboardPayload {
    FFRClipboardFormatKind kind;
    uint32_t formatId;
    uint8_t *bytes;
    size_t length;
} FFRStoredClipboardPayload;

typedef struct FFRClipboardLocalFileRequest {
    bool active;
    bool responseReady;
    bool success;
    uint64_t requestId;
    uint64_t generation;
    uint32_t streamId;
    uint32_t listIndex;
    FFRClipboardFileRequestKind kind;
    uint64_t offset;
    uint32_t requestedBytes;
    uint8_t *responseBytes;
    size_t responseLength;
} FFRClipboardLocalFileRequest;

enum { FFR_INPUT_QUEUE_CAPACITY = 512 };

struct FFRSession {
    freerdp *instance;
    pthread_t ownerThread;
    atomic_bool cancellationRequested;
    atomic_bool connectionActive;
    atomic_bool inputEnabled;
    pthread_mutex_t decisionMutex;
    pthread_mutex_t inputMutex;
    HANDLE inputEvent;
    FFRQueuedInput inputQueue[FFR_INPUT_QUEUE_CAPACITY];
    size_t inputQueueHead;
    size_t inputQueueCount;
    bool pressedScanCodes[512];
    uint16_t pressedPointerButtons;
    uint16_t lastPointerX;
    uint16_t lastPointerY;
    pthread_cond_t decisionCondition;
    bool waitingForCertificate;
    bool certificateDecisionReady;
    FFRCertificateDecision certificateDecision;
    unsigned int authenticationCallbacks;
    bool certificateRejected;
    bool certificateWasChanged;
    FFRSecurityProtocol negotiatedSecurityProtocol;
    FFRSessionState state;
    FFREventCallback callback;
    void *callbackContext;
    FFRGraphicsEventCallback graphicsCallback;
    void *graphicsCallbackContext;
    uint64_t graphicsSequenceNumber;
    FFRClipboardEventCallback clipboardCallback;
    void *clipboardCallbackContext;
    pthread_mutex_t clipboardMutex;
    CliprdrClientContext *clipboard;
    bool clipboardEnabled;
    bool clipboardTextAllowed;
    bool clipboardFormattedTextAllowed;
    bool clipboardImagesAllowed;
    bool clipboardFilesAllowed;
    bool clipboardLocalToRemote;
    bool clipboardRemoteToLocal;
    bool clipboardReady;
    bool remoteClipboardLockSupported;
    bool remoteClipboardLocked;
    uint64_t lockedRemoteClipboardGeneration;
    uint32_t remoteClipboardClipDataId;
    uint64_t localClipboardGeneration;
    FFRStoredClipboardPayload localClipboardPayloads[FFR_MAX_CLIPBOARD_FORMATS];
    size_t localClipboardPayloadCount;
    uint64_t remoteClipboardGeneration;
    bool clipboardRequestPending;
    uint64_t pendingClipboardGeneration;
    uint32_t pendingClipboardFormatId;
    FFRClipboardFormatKind pendingClipboardFormat;
    uint64_t nextFileRequestId;
    FFRClipboardLocalFileRequest localFileRequests[FFR_MAX_CLIPBOARD_FILE_REQUESTS];
    bool remoteFileRequestPending;
    uint64_t pendingRemoteFileGeneration;
    uint32_t pendingRemoteFileStreamId;
    uint32_t pendingRemoteFileListIndex;
    FFRClipboardFileRequestKind pendingRemoteFileKind;
    uint64_t pendingRemoteFileOffset;
    uint32_t pendingRemoteFileRequestedBytes;
    DispClientContext *displayControl;
    bool dynamicResolutionEnabled;
    bool displayControlActivated;
    RdpgfxClientContext *graphicsPipeline;
    bool graphicsPipelineActive;
    bool hasPendingResize;
    uint32_t pendingResizeWidth;
    uint32_t pendingResizeHeight;
    FFRMonitorLayout pendingMonitorLayout[FFR_MAX_MONITOR_LAYOUTS];
    size_t pendingMonitorCount;
};

bool FFRSessionIsOwnedByCurrentThread(const FFRSession *session);
FFRSession *FFRSessionFromInstance(freerdp *instance);
FFRConnectionFailure FFRMapConnectionFailure(uint32_t error);
FFRConnectionFailure FFRMapConnectionFailureForState(uint32_t error,
                                                      CONNECTION_STATE state);
void FFREmitEvent(FFRSession *session,
                  FFREventType type,
                  FFRResult result,
                  FFRConnectionFailure failure,
                  uint32_t nativeErrorCode,
                  const FFRCertificateInfo *certificate);
void FFREmitGraphicsEvent(FFRSession *session, const FFRGraphicsEvent *event);
void FFREmitClipboardEvent(FFRSession *session, const FFRClipboardEvent *event);
bool FFRProcessPendingInput(FFRSession *session);
void FFRReleasePressedInputOnOwnerThread(FFRSession *session);
bool FFRValidateResizeDimensions(uint32_t width, uint32_t height);
bool FFRValidateMonitorLayout(const FFRMonitorLayout *monitors, size_t monitorCount);
bool FFRValidateDesktopGeometry(uint32_t width, uint32_t height,
                                uint32_t stride, size_t *bufferLength);
bool FFRValidateDirtyRectangle(int32_t x, int32_t y, int32_t width, int32_t height,
                               uint32_t desktopWidth, uint32_t desktopHeight);
bool FFRValidateCursorGeometry(uint32_t width, uint32_t height,
                              uint32_t hotspotX, uint32_t hotspotY,
                              size_t *bufferLength);
bool FFRSendPendingResize(FFRSession *session);
bool FFRSendClipboardFormatList(FFRSession *session);
bool FFRSendClipboardDataRequest(FFRSession *session,
                                 uint64_t generation,
                                 uint32_t remoteFormatId,
                                 FFRClipboardFormatKind format);
bool FFRSendClipboardFileResponse(FFRSession *session, uint64_t requestId);
bool FFRSendClipboardFileRequest(FFRSession *session,
                                 uint64_t generation,
                                 uint32_t streamId,
                                 uint32_t listIndex,
                                 FFRClipboardFileRequestKind kind,
                                 uint64_t offset,
                                 uint32_t requestedBytes);
bool FFRSendClipboardLock(FFRSession *session, uint64_t generation);
bool FFRSendClipboardUnlock(FFRSession *session, uint64_t generation);
void FFRClearClipboardState(FFRSession *session);
size_t FFRClipboardUTF16Length(const BYTE *data, UINT32 byteLength);
bool FFRClipboardFormatAllowed(const FFRSession *session,
                               FFRClipboardFormatKind format,
                               bool localToRemote);
/// Maps only allowlisted remote formats. Names and payloads remain untrusted.
bool FFRClipboardRemoteFormat(const CLIPRDR_FORMAT *format,
                              FFRClipboardFormatKind *kind);

#endif

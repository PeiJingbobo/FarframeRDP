#ifndef FARFRAME_RDP_BRIDGE_INTERNAL_H
#define FARFRAME_RDP_BRIDGE_INTERNAL_H

#include "FarframeRDPBridge.h"

#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
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
    FFR_QUEUED_INPUT_CLIPBOARD_TEXT = 9
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
} FFRQueuedInput;

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
    bool clipboardTextEnabled;
    bool clipboardReady;
    uint16_t *localClipboardUtf16;
    size_t localClipboardLength;
    DispClientContext *displayControl;
    bool dynamicResolutionEnabled;
    bool displayControlActivated;
    bool hasPendingResize;
    uint32_t pendingResizeWidth;
    uint32_t pendingResizeHeight;
    FFRMonitorLayout pendingMonitorLayout[FFR_MAX_MONITOR_LAYOUTS];
    size_t pendingMonitorCount;
};

bool FFRSessionIsOwnedByCurrentThread(const FFRSession *session);
FFRSession *FFRSessionFromInstance(freerdp *instance);
FFRConnectionFailure FFRMapConnectionFailure(uint32_t error);
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
void FFRClearClipboardState(FFRSession *session);
size_t FFRClipboardUTF16Length(const BYTE *data, UINT32 byteLength);

#endif

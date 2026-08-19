#ifndef FARFRAME_RDP_BRIDGE_H
#define FARFRAME_RDP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FFRSession FFRSession;

typedef enum FFRResult {
    FFR_RESULT_OK = 0,
    FFR_RESULT_INVALID_ARGUMENT = 1,
    FFR_RESULT_ALLOCATION_FAILED = 2,
    FFR_RESULT_CONTEXT_CREATION_FAILED = 3,
    FFR_RESULT_THREAD_VIOLATION = 4,
    FFR_RESULT_INVALID_STATE = 5,
    FFR_RESULT_SETTINGS_FAILED = 6,
    FFR_RESULT_CONNECTION_FAILED = 7,
    FFR_RESULT_CANCELLED = 8,
    FFR_RESULT_INPUT_QUEUE_FULL = 9
} FFRResult;

typedef enum FFRConnectionFailure {
    FFR_CONNECTION_FAILURE_NONE = 0,
    FFR_CONNECTION_FAILURE_DNS = 1,
    FFR_CONNECTION_FAILURE_NETWORK = 2,
    FFR_CONNECTION_FAILURE_TLS = 3,
    FFR_CONNECTION_FAILURE_CERTIFICATE_REJECTED = 4,
    FFR_CONNECTION_FAILURE_CERTIFICATE_CHANGED = 5,
    FFR_CONNECTION_FAILURE_AUTHENTICATION = 6,
    FFR_CONNECTION_FAILURE_SERVER_REFUSED = 7,
    FFR_CONNECTION_FAILURE_PROTOCOL = 8,
    FFR_CONNECTION_FAILURE_CANCELLED = 9,
    FFR_CONNECTION_FAILURE_SECURITY_NEGOTIATION = 10,
    FFR_CONNECTION_FAILURE_GATEWAY_AUTHENTICATION = 11,
    FFR_CONNECTION_FAILURE_GATEWAY_ACCESS_DENIED = 12
} FFRConnectionFailure;

typedef enum FFRSecurityProtocol {
    FFR_SECURITY_PROTOCOL_UNKNOWN = 0,
    FFR_SECURITY_PROTOCOL_RDP = 1,
    FFR_SECURITY_PROTOCOL_TLS = 2,
    FFR_SECURITY_PROTOCOL_NLA = 3,
    FFR_SECURITY_PROTOCOL_RDSTLS = 4
} FFRSecurityProtocol;

typedef enum FFRCertificateDecision {
    FFR_CERTIFICATE_REJECT = 0,
    FFR_CERTIFICATE_ACCEPT_AND_STORE = 1,
    FFR_CERTIFICATE_ACCEPT_FOR_SESSION = 2
} FFRCertificateDecision;

typedef enum FFREventType {
    FFR_EVENT_SESSION_CREATED = 1,
    FFR_EVENT_SESSION_WILL_DESTROY = 2,
    FFR_EVENT_RESOLVING = 3,
    FFR_EVENT_CONNECTING = 4,
    FFR_EVENT_AUTHENTICATING = 5,
    FFR_EVENT_CERTIFICATE_REQUESTED = 6,
    FFR_EVENT_CONNECTED = 7,
    FFR_EVENT_DISCONNECTING = 8,
    FFR_EVENT_DISCONNECTED = 9,
    FFR_EVENT_FAILED = 10,
    /// The negotiated display-control channel can now accept monitor layouts.
    FFR_EVENT_DISPLAY_CONTROL_READY = 11
} FFREventType;

typedef struct FFRConnectionSettings {
    const char *hostname;
    uint16_t port;
    const char *username;
    const char *domain;
    const char *password;
    /// Existing, session-isolated directory used only for FreeRDP certificate lookup.
    /// The Bridge copies this path into FreeRDP settings and never logs it.
    const char *certificateStorePath;
    /// Enables the RDPEDISP dynamic display-control channel. When enabled, the
    /// bridge may send monitor-layout updates from the owner thread while the
    /// session is connected.
    bool dynamicResolution;
    /// Enables CF_UNICODETEXT when clipboard redirection is active.
    bool clipboardText;
    /// Enables registered HTML/RTF formats. Payloads remain bounded opaque
    /// bytes; the bridge never renders them.
    bool clipboardFormattedText;
    /// Enables PNG, CF_DIB, and CF_DIBV5 with fixed encoded-size limits.
    bool clipboardImages;
    /// Enables FileGroupDescriptorW. File streaming still requires the
    /// dedicated bounded file APIs and capability negotiation.
    bool clipboardFiles;
    /// Direction policy. If clipboard is enabled and both are false, both are
    /// enabled for source compatibility with callers built against ABI 12.
    bool clipboardLocalToRemote;
    bool clipboardRemoteToLocal;
    /// Enables remote audio playback through FreeRDP rdpsnd. On macOS builds
    /// Farframe uses FreeRDP's Core Audio backend and follows the system output
    /// device; drive, printer, smart-card, and other device mappings remain
    /// disabled unless configured by a later feature.
    bool audioPlayback;
    /// Enables microphone input redirection through FreeRDP audin. The bridge
    /// only requests the channel; macOS microphone permission remains controlled
    /// by the system and denial must not prevent a normal desktop session when
    /// this field is false.
    bool microphoneRedirection;
    /// Optional audin device name. NULL or empty uses the backend default.
    const char *microphoneDeviceName;
    /// Optional, explicitly user-selected local directory to expose as a single
    /// RDP drive named "Farframe". NULL disables directory redirection. The
    /// bridge requires the path to resolve to an existing local directory.
    const char *redirectedDirectoryPath;
    /// Optional RD Gateway host. NULL disables RD Gateway. When present, the
    /// bridge enables explicit direct gateway usage over HTTPS/RPC compatible
    /// transport and keeps TLS/NLA certificate validation active.
    const char *gatewayHostname;
    uint16_t gatewayPort;
    /// When true, FreeRDP copies target username/domain/password into gateway
    /// credentials. When false, gatewayUsername/domain/password must all be
    /// supplied as bounded UTF-8 strings; passwords remain borrowed only for
    /// this configure call.
    bool gatewayUseSameCredentials;
    const char *gatewayUsername;
    const char *gatewayDomain;
    const char *gatewayPassword;
    /// Optional RemoteApp program identifier or executable path. NULL keeps
    /// the session in full-desktop mode. When present, the bridge enables
    /// FreeRDP RemoteApplicationMode and requests the RAIL static channel.
    const char *remoteAppProgram;
    const char *remoteAppArguments;
    const char *remoteAppWorkingDirectory;
} FFRConnectionSettings;

typedef struct FFRCertificateInfo {
    const char *hostname;
    uint16_t port;
    const char *commonName;
    const char *subject;
    const char *issuer;
    const char *fingerprint;
    const char *oldSubject;
    const char *oldIssuer;
    const char *oldFingerprint;
    bool hostnameMismatch;
    bool changed;
} FFRCertificateInfo;

typedef struct FFREvent {
    FFREventType type;
    FFRResult result;
    FFRConnectionFailure failure;
    uint32_t nativeErrorCode;
    const FFRCertificateInfo *certificate;
} FFREvent;

typedef enum FFRGraphicsEventType {
    FFR_GRAPHICS_EVENT_DESKTOP_SIZE = 1,
    FFR_GRAPHICS_EVENT_FRAME = 2,
    FFR_GRAPHICS_EVENT_CURSOR_SHAPE = 3,
    FFR_GRAPHICS_EVENT_CURSOR_POSITION = 4,
    FFR_GRAPHICS_EVENT_CURSOR_HIDDEN = 5,
    FFR_GRAPHICS_EVENT_CURSOR_DEFAULT = 6
} FFRGraphicsEventType;

typedef struct FFRDirtyRect {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
} FFRDirtyRect;

typedef struct FFRMonitorLayout {
    int32_t left;
    int32_t top;
    uint32_t width;
    uint32_t height;
    uint32_t desktopScaleFactor;
    uint32_t deviceScaleFactor;
    bool primary;
} FFRMonitorLayout;

typedef enum FFRPointerButton {
    FFR_POINTER_BUTTON_LEFT = 1,
    FFR_POINTER_BUTTON_RIGHT = 2,
    FFR_POINTER_BUTTON_MIDDLE = 3,
    FFR_POINTER_BUTTON_X1 = 4,
    FFR_POINTER_BUTTON_X2 = 5
} FFRPointerButton;

typedef struct FFRGraphicsEvent {
    FFRGraphicsEventType type;
    uint32_t desktopWidth;
    uint32_t desktopHeight;
    uint32_t sourceStride;
    const uint8_t *pixels;
    size_t bufferLength;
    FFRDirtyRect dirtyRect;
    uint32_t cursorWidth;
    uint32_t cursorHeight;
    uint32_t cursorHotspotX;
    uint32_t cursorHotspotY;
    uint32_t cursorX;
    uint32_t cursorY;
    uint64_t sequenceNumber;
} FFRGraphicsEvent;

typedef enum FFRClipboardEventType {
    FFR_CLIPBOARD_EVENT_READY = 1,
    FFR_CLIPBOARD_EVENT_REMOTE_TEXT = 2,
    /// A new remote clipboard generation is available. `formats` is borrowed.
    FFR_CLIPBOARD_EVENT_REMOTE_OFFER = 3,
    /// Payload for a request previously submitted with FFRSessionRequestClipboardData.
    FFR_CLIPBOARD_EVENT_REMOTE_DATA = 4,
    FFR_CLIPBOARD_EVENT_LOCAL_FILE_REQUEST = 5,
    FFR_CLIPBOARD_EVENT_REMOTE_FILE_DATA = 6
} FFRClipboardEventType;

typedef enum FFRClipboardFileRequestKind {
    FFR_CLIPBOARD_FILE_REQUEST_SIZE = 1,
    FFR_CLIPBOARD_FILE_REQUEST_RANGE = 2
} FFRClipboardFileRequestKind;

typedef enum FFRClipboardFormatKind {
    FFR_CLIPBOARD_FORMAT_UNICODE_TEXT = 1,
    FFR_CLIPBOARD_FORMAT_HTML = 2,
    FFR_CLIPBOARD_FORMAT_RTF = 3,
    FFR_CLIPBOARD_FORMAT_DIB = 4,
    FFR_CLIPBOARD_FORMAT_DIBV5 = 5,
    FFR_CLIPBOARD_FORMAT_FILE_LIST = 6,
    /// Registered Windows clipboard format named "PNG".
    FFR_CLIPBOARD_FORMAT_PNG = 7
} FFRClipboardFormatKind;

typedef struct FFRClipboardFormatDescriptor {
    FFRClipboardFormatKind kind;
    /// Format ID in the namespace of the endpoint that owns the offer.
    uint32_t formatId;
} FFRClipboardFormatDescriptor;

typedef struct FFRClipboardPayload {
    FFRClipboardFormatKind kind;
    /// Native cliprdr payload. The Bridge copies it during publication.
    const uint8_t *bytes;
    size_t length;
} FFRClipboardPayload;

typedef struct FFRClipboardEvent {
    FFRClipboardEventType type;
    /// UTF-16 code units borrowed for the callback duration. The length excludes
    /// the terminating NUL from CF_UNICODETEXT.
    const uint16_t *utf16CodeUnits;
    size_t length;
    /// Monotonic remote clipboard generation. A newer offer supersedes all
    /// requests and responses from older generations.
    uint64_t generation;
    /// Borrowed descriptors for REMOTE_OFFER only.
    const FFRClipboardFormatDescriptor *formats;
    size_t formatCount;
    /// Requested format and borrowed bytes for REMOTE_DATA only.
    FFRClipboardFormatKind format;
    const uint8_t *bytes;
    /// File events only. `fileRequestId` is an opaque correlation token.
    uint64_t fileRequestId;
    uint32_t streamId;
    uint32_t listIndex;
    FFRClipboardFileRequestKind fileRequestKind;
    uint64_t fileOffset;
    uint32_t requestedBytes;
    bool success;
} FFRClipboardEvent;

/// Called synchronously on the session owner thread.
///
/// All pointers in the event are borrowed for the callback duration. Copy
/// certificate fields before returning. The callback must not destroy the
/// session or re-enter owner-thread Bridge functions. Submit a certificate
/// decision asynchronously with FFRSessionResolveCertificate.
typedef void (*FFREventCallback)(FFRSession *session,
                                 const FFREvent *event,
                                 void *userContext);

/// Called synchronously on the session owner thread for desktop-size and frame updates.
///
/// Pixel memory is BGRA32 and borrowed only for the callback duration. The callback
/// must copy any bytes it needs before returning. It must not destroy the session or
/// re-enter owner-thread Bridge functions. Frame rectangles are validated and bounded
/// to the announced desktop before delivery.
typedef void (*FFRGraphicsEventCallback)(FFRSession *session,
                                         const FFRGraphicsEvent *event,
                                         void *userContext);

/// Called synchronously on the session owner thread for clipboard channel events.
///
/// Text data is UTF-16 and borrowed only for the callback duration. The callback
/// must copy it before returning, must not log clipboard contents, and must not
/// destroy the session or re-enter owner-thread Bridge functions.
typedef void (*FFRClipboardEventCallback)(FFRSession *session,
                                          const FFRClipboardEvent *event,
                                          void *userContext);

uint32_t FFRBridgeABIVersion(void);

/// Process-lifetime strings owned by FreeRDP. Callers must not free them.
const char *FFRFreeRDPVersion(void);
const char *FFRFreeRDPBuildRevision(void);

/// Process-lifetime diagnostic strings that contain no user data.
const char *FFRResultDescription(FFRResult result);
const char *FFRConnectionFailureDescription(FFRConnectionFailure failure);

/// Creates a session and its FreeRDP context.
///
/// The returned session has one owner. Creation, configuration, connection,
/// callback mutation, and destruction must occur on the creating thread.
FFRResult FFRSessionCreate(FFREventCallback callback,
                           void *userContext,
                           FFRSession **outSession);

FFRResult FFRSessionSetEventCallback(FFRSession *session,
                                     FFREventCallback callback,
                                     void *userContext);

/// Installs the graphics consumer before connecting. The callback and its context
/// remain borrowed until the session finishes or the callback is replaced.
FFRResult FFRSessionSetGraphicsEventCallback(FFRSession *session,
                                             FFRGraphicsEventCallback callback,
                                             void *userContext);

/// Installs the clipboard consumer before connecting. The callback and context
/// remain borrowed until the session finishes or the callback is replaced.
FFRResult FFRSessionSetClipboardEventCallback(FFRSession *session,
                                              FFRClipboardEventCallback callback,
                                              void *userContext);

/// Copies validated settings into the owned FreeRDP context.
///
/// Strings are borrowed only for this call. Hostname and username must be
/// non-empty UTF-8 strings. An empty domain or password is valid.
FFRResult FFRSessionConfigure(FFRSession *session,
                              const FFRConnectionSettings *settings);

/// Runs the blocking connect and event loop on the owner thread.
///
/// The call returns after cancellation, disconnect, or failure. Keep the
/// session alive until it returns, then destroy it on the same owner thread.
FFRResult FFRSessionConnect(FFRSession *session);

/// Returns the protocol selected by the completed FreeRDP negotiation.
FFRSecurityProtocol FFRSessionNegotiatedSecurityProtocol(const FFRSession *session);

/// Reports whether this configured session requests the RDP Graphics Pipeline.
/// Full desktop sessions request RDPGFX with Progressive and AVC codecs;
/// RemoteApp sessions keep the legacy graphics path until window-surface mapping
/// is integrated. Call this read-only diagnostic on the session owner thread; it
/// exposes no FreeRDP pointer.
bool FFRSessionGraphicsPipelineRequested(const FFRSession *session);

/// Atomically requests cancellation and wakes FreeRDP. May run on any thread
/// while the caller guarantees that the session remains alive.
FFRResult FFRSessionRequestCancellation(FFRSession *session);
bool FFRSessionIsCancellationRequested(const FFRSession *session);

/// Resolves a pending certificate request. May run on any thread while the
/// caller guarantees that the session remains alive.
FFRResult FFRSessionResolveCertificate(FFRSession *session,
                                       FFRCertificateDecision decision);

/// Enqueues input from any thread while the session is connected. The Bridge
/// copies values into a bounded queue and sends them from the owner thread.
/// The caller must keep the session alive for the duration of each call.
FFRResult FFRSessionSendScanCode(FFRSession *session,
                                 uint32_t scanCode,
                                 bool down,
                                 bool repeat);
FFRResult FFRSessionSendUnicode(FFRSession *session,
                                const uint16_t *utf16CodeUnits,
                                size_t length);
FFRResult FFRSessionSendPointerMove(FFRSession *session, uint16_t x, uint16_t y);
FFRResult FFRSessionSendPointerButton(FFRSession *session,
                                      FFRPointerButton button,
                                      bool down,
                                      uint16_t x,
                                      uint16_t y);
FFRResult FFRSessionSendPointerWheel(FFRSession *session,
                                     int16_t delta,
                                     bool horizontal,
                                     uint16_t x,
                                     uint16_t y);
FFRResult FFRSessionSynchronizeLocks(FFRSession *session,
                                     bool capsLock,
                                     bool numLock,
                                     bool scrollLock);

/// Requests a single-monitor desktop resize through the RDP display-control
/// channel. Safe from any thread while the session is connected; the Bridge
/// coalesces pending resize requests and sends them from the owner thread.
FFRResult FFRSessionRequestResize(FFRSession *session, uint32_t width, uint32_t height);

/// Requests a multi-monitor layout through the RDP display-control channel.
/// The array is copied into the Bridge input queue, bounded to 16 monitors, and
/// sent from the owner thread. Exactly one monitor must be marked primary.
FFRResult FFRSessionRequestMonitorLayout(FFRSession *session,
                                         const FFRMonitorLayout *monitors,
                                         size_t monitorCount);

/// Publishes the current local plain-text clipboard to the remote session.
///
/// Passing length 0 clears the local text offer. Non-empty values must not
/// include embedded NUL code units. The bridge copies the UTF-16 payload,
/// appends the CF_UNICODETEXT terminator, and sends only from the owner thread.
FFRResult FFRSessionPublishClipboardText(FFRSession *session,
                                         const uint16_t *utf16CodeUnits,
                                         size_t length);

/// Replaces the current local clipboard offer with copied, validated payloads.
/// Safe from any thread while connected. The generation must be non-zero and
/// monotonically increase for a session. Payload memory is borrowed only for
/// this call. An empty array clears the offer.
FFRResult FFRSessionPublishClipboardOffer(FFRSession *session,
                                          uint64_t generation,
                                          const FFRClipboardPayload *payloads,
                                          size_t payloadCount);

/// Requests one format from the current remote clipboard offer. Safe from any
/// thread while connected. Only one format-data request may be outstanding;
/// stale generations and overlapping requests are rejected.
FFRResult FFRSessionRequestClipboardData(FFRSession *session,
                                         uint64_t generation,
                                         uint32_t remoteFormatId,
                                         FFRClipboardFormatKind format);

/// Completes a LOCAL_FILE_REQUEST asynchronously. RANGE payloads are capped at
/// 1 MiB and SIZE payloads must contain one little-endian uint64.
FFRResult FFRSessionRespondLocalFileRequest(FFRSession *session,
                                            uint64_t fileRequestId,
                                            bool success,
                                            const uint8_t *bytes,
                                            size_t length);

/// Requests one remote file size or range. Only one request is in flight.
FFRResult FFRSessionRequestRemoteFileContents(FFRSession *session,
                                              uint64_t generation,
                                              uint32_t streamId,
                                              uint32_t listIndex,
                                              FFRClipboardFileRequestKind kind,
                                              uint64_t offset,
                                              uint32_t requestedBytes);

/// Drops unsent input and enqueues a release barrier. The owner thread releases
/// every scan code and pointer button known to be down. Safe from any thread.
FFRResult FFRSessionReleaseAllInput(FFRSession *session);

bool FFRSessionOwnsCurrentThread(const FFRSession *session);

/// Releases all native state exactly once. The session must not be connecting.
///
/// Must run on the owner thread. NULL is a successful no-op. On success the
/// caller's pointer is set to NULL.
FFRResult FFRSessionDestroy(FFRSession **session);

size_t FFRBridgeLiveSessionCount(void);

#ifdef __cplusplus
}
#endif

#endif

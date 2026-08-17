#include "FarframeRDPBridgeInternal.h"

#include <freerdp/client/cmdline.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/audin.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/rdpsnd.h>
#include <freerdp/error.h>
#include <freerdp/input.h>
#include <freerdp/rail.h>
#include <freerdp/scancode.h>
#include <freerdp/settings.h>
#include <freerdp/settings_types.h>
#include <winpr/error.h>
#include <winpr/input.h>
#include <winpr/synch.h>

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef E_PROXY_RAP_ACCESSDENIED
#define E_PROXY_RAP_ACCESSDENIED 0x800759DAU
#endif
#ifndef E_PROXY_NAP_ACCESSDENIED
#define E_PROXY_NAP_ACCESSDENIED 0x800759DBU
#endif
#ifndef E_PROXY_QUARANTINE_ACCESSDENIED
#define E_PROXY_QUARANTINE_ACCESSDENIED 0x800759EDU
#endif
#ifndef E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED
#define E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED 0x800759F8U
#endif
#ifndef E_PROXY_REAUTH_AUTHN_FAILED
#define E_PROXY_REAUTH_AUTHN_FAILED 0x000059FAU
#endif

enum {
    FFR_MAX_HOSTNAME_LENGTH = 255,
    FFR_MAX_USERNAME_LENGTH = 512,
    FFR_MAX_DOMAIN_LENGTH = 512,
    FFR_MAX_PASSWORD_LENGTH = 4096,
    FFR_MAX_CERTIFICATE_STORE_PATH_LENGTH = 4096,
    FFR_MAX_MICROPHONE_DEVICE_NAME_LENGTH = 512,
    FFR_MAX_REDIRECTED_DIRECTORY_PATH_LENGTH = 4096,
    FFR_MAX_GATEWAY_HOSTNAME_LENGTH = 255,
    FFR_MAX_GATEWAY_USERNAME_LENGTH = 512,
    FFR_MAX_GATEWAY_DOMAIN_LENGTH = 512,
    FFR_MAX_GATEWAY_PASSWORD_LENGTH = 4096,
    FFR_MAX_REMOTE_APP_FIELD_LENGTH = 4096,
    FFR_MAX_EVENT_HANDLES = 64
};

static bool FFRStringIsValid(const char *value, size_t maximumLength, bool allowEmpty)
{
    if (value == NULL) {
        return false;
    }
    const size_t length = strnlen(value, maximumLength + 1U);
    return length <= maximumLength && (allowEmpty || length > 0U);
}

static bool FFROptionalStringIsValid(const char *value, size_t maximumLength)
{
    if (value == NULL) {
        return true;
    }
    return FFRStringIsValid(value, maximumLength, false);
}

static bool FFROptionalPossiblyEmptyStringIsValid(const char *value,
                                                  size_t maximumLength)
{
    if (value == NULL) {
        return true;
    }
    return FFRStringIsValid(value, maximumLength, true);
}

static bool FFRResolveExistingDirectory(const char *path,
                                        char resolvedPath[PATH_MAX])
{
    if (path == NULL) {
        return true;
    }
    if (realpath(path, resolvedPath) == NULL) {
        return false;
    }
    struct stat info;
    if (stat(resolvedPath, &info) != 0) {
        return false;
    }
    return S_ISDIR(info.st_mode);
}

static bool FFRAddStaticChannel(rdpSettings *settings, const char *channelName)
{
    const char *params[] = { channelName };
    return freerdp_client_add_static_channel(settings, 1U, params);
}

static bool FFRAddDynamicChannel(rdpSettings *settings, const char *channelName)
{
    const char *params[] = { channelName };
    return freerdp_client_add_dynamic_channel(settings, 1U, params);
}

static bool FFRAddAudinChannel(rdpSettings *settings, const char *deviceName)
{
    if (deviceName != NULL && deviceName[0] != '\0') {
        const char *params[] = { AUDIN_CHANNEL_NAME, "sys:mac", deviceName };
        char deviceArgument[FFR_MAX_MICROPHONE_DEVICE_NAME_LENGTH + 5U] = {0};
        if (snprintf(deviceArgument, sizeof(deviceArgument), "dev:%s", deviceName) < 0) {
            return false;
        }
        params[2] = deviceArgument;
        return freerdp_client_add_dynamic_channel(settings, 3U, params);
    }
    const char *params[] = { AUDIN_CHANNEL_NAME, "sys:mac" };
    return freerdp_client_add_dynamic_channel(settings, 2U, params);
}

static BOOL FFRLoadChannels(freerdp *instance)
{
    if (instance == NULL || instance->context == NULL ||
        instance->context->channels == NULL || instance->context->settings == NULL) {
        return FALSE;
    }
    return freerdp_client_load_addins(instance->context->channels,
                                      instance->context->settings);
}

static FFRSecurityProtocol FFRMapSecurityProtocol(uint32_t selected)
{
    switch (selected) {
    case 0x00000000U:
        return FFR_SECURITY_PROTOCOL_RDP;
    case 0x00000001U:
        return FFR_SECURITY_PROTOCOL_TLS;
    case 0x00000002U:
    case 0x00000008U:
        return FFR_SECURITY_PROTOCOL_NLA;
    case 0x00000004U:
        return FFR_SECURITY_PROTOCOL_RDSTLS;
    default:
        return FFR_SECURITY_PROTOCOL_UNKNOWN;
    }
}

FFRConnectionFailure FFRMapConnectionFailure(uint32_t error)
{
    switch (error) {
    case FREERDP_ERROR_DNS_ERROR:
    case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
        return FFR_CONNECTION_FAILURE_DNS;
    case FREERDP_ERROR_CONNECT_FAILED:
    case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
        return FFR_CONNECTION_FAILURE_NETWORK;
    case FREERDP_ERROR_TLS_CONNECT_FAILED:
        return FFR_CONNECTION_FAILURE_TLS;
    case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED:
        return FFR_CONNECTION_FAILURE_SECURITY_NEGOTIATION;
    case RPC_S_INVALID_AUTH_IDENTITY:
    case E_PROXY_REAUTH_AUTHN_FAILED:
    case E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED:
        return FFR_CONNECTION_FAILURE_GATEWAY_AUTHENTICATION;
    case RPC_S_PROXY_ACCESS_DENIED:
    case E_PROXY_RAP_ACCESSDENIED:
    case E_PROXY_NAP_ACCESSDENIED:
    case E_PROXY_QUARANTINE_ACCESSDENIED:
        return FFR_CONNECTION_FAILURE_GATEWAY_ACCESS_DENIED;
    case FREERDP_ERROR_AUTHENTICATION_FAILED:
    case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
    case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
    case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
    case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
    case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED:
    case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
    case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
    case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
    case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
    case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
        return FFR_CONNECTION_FAILURE_AUTHENTICATION;
    case FREERDP_ERROR_INSUFFICIENT_PRIVILEGES:
    case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
    case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
        return FFR_CONNECTION_FAILURE_SERVER_REFUSED;
    case FREERDP_ERROR_CONNECT_CANCELLED:
        return FFR_CONNECTION_FAILURE_CANCELLED;
    default:
        return FFR_CONNECTION_FAILURE_PROTOCOL;
    }
}

static DWORD FFRWaitForCertificateDecision(FFRSession *session,
                                           const FFRCertificateInfo *certificate)
{
    if (pthread_mutex_lock(&session->decisionMutex) != 0) {
        return (DWORD)FFR_CERTIFICATE_REJECT;
    }
    session->waitingForCertificate = true;
    session->certificateDecisionReady = false;
    session->certificateDecision = FFR_CERTIFICATE_REJECT;
    pthread_mutex_unlock(&session->decisionMutex);

    FFREmitEvent(session, FFR_EVENT_AUTHENTICATING, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);
    FFREmitEvent(session, FFR_EVENT_CERTIFICATE_REQUESTED, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, certificate);

    if (pthread_mutex_lock(&session->decisionMutex) != 0) {
        return (DWORD)FFR_CERTIFICATE_REJECT;
    }
    while (!session->certificateDecisionReady &&
           !atomic_load_explicit(&session->cancellationRequested, memory_order_acquire)) {
        if (pthread_cond_wait(&session->decisionCondition, &session->decisionMutex) != 0) {
            break;
        }
    }

    const FFRCertificateDecision decision =
        session->certificateDecisionReady ? session->certificateDecision : FFR_CERTIFICATE_REJECT;
    session->waitingForCertificate = false;
    session->certificateDecisionReady = false;
    pthread_mutex_unlock(&session->decisionMutex);

    if (decision == FFR_CERTIFICATE_REJECT) {
        session->certificateRejected = true;
    }
    return (DWORD)decision;
}

static DWORD FFRVerifyCertificate(freerdp *instance,
                                  const char *host,
                                  UINT16 port,
                                  const char *commonName,
                                  const char *subject,
                                  const char *issuer,
                                  const char *fingerprint,
                                  DWORD flags)
{
    FFRSession *session = FFRSessionFromInstance(instance);
    if (session == NULL) {
        return (DWORD)FFR_CERTIFICATE_REJECT;
    }

    const FFRCertificateInfo certificate = {
        .hostname = host,
        .port = port,
        .commonName = commonName,
        .subject = subject,
        .issuer = issuer,
        .fingerprint = fingerprint,
        .oldSubject = NULL,
        .oldIssuer = NULL,
        .oldFingerprint = NULL,
        .hostnameMismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0U,
        .changed = false,
    };
    return FFRWaitForCertificateDecision(session, &certificate);
}

static DWORD FFRVerifyChangedCertificate(freerdp *instance,
                                         const char *host,
                                         UINT16 port,
                                         const char *commonName,
                                         const char *subject,
                                         const char *issuer,
                                         const char *newFingerprint,
                                         const char *oldSubject,
                                         const char *oldIssuer,
                                         const char *oldFingerprint,
                                         DWORD flags)
{
    FFRSession *session = FFRSessionFromInstance(instance);
    if (session == NULL) {
        return (DWORD)FFR_CERTIFICATE_REJECT;
    }
    session->certificateWasChanged = true;

    const FFRCertificateInfo certificate = {
        .hostname = host,
        .port = port,
        .commonName = commonName,
        .subject = subject,
        .issuer = issuer,
        .fingerprint = newFingerprint,
        .oldSubject = oldSubject,
        .oldIssuer = oldIssuer,
        .oldFingerprint = oldFingerprint,
        .hostnameMismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0U,
        .changed = true,
    };
    return FFRWaitForCertificateDecision(session, &certificate);
}

static BOOL FFRAuthenticate(freerdp *instance,
                            char **username,
                            char **password,
                            char **domain,
                            rdp_auth_reason reason)
{
    (void)reason;
    FFRSession *session = FFRSessionFromInstance(instance);
    if (session == NULL || username == NULL || password == NULL || domain == NULL) {
        return FALSE;
    }

    FFREmitEvent(session, FFR_EVENT_AUTHENTICATING, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);

    /* Permit the original values, including an intentional empty password,
       once. A second callback means those credentials were rejected. */
    session->authenticationCallbacks += 1U;
    return session->authenticationCallbacks == 1U && *username != NULL &&
           *password != NULL && *domain != NULL;
}

static FFRResult FFREnqueueInput(FFRSession *session,
                                 const FFRQueuedInput *events,
                                 size_t count,
                                 bool replacesPendingInput)
{
    if (session == NULL || events == NULL || count == 0U ||
        count > FFR_INPUT_QUEUE_CAPACITY) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    if (!atomic_load_explicit(&session->inputEnabled, memory_order_acquire)) {
        return FFR_RESULT_INVALID_STATE;
    }
    if (pthread_mutex_lock(&session->inputMutex) != 0) {
        return FFR_RESULT_INVALID_STATE;
    }
    if (!atomic_load_explicit(&session->inputEnabled, memory_order_acquire)) {
        pthread_mutex_unlock(&session->inputMutex);
        return FFR_RESULT_INVALID_STATE;
    }

    if (replacesPendingInput) {
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
    }

    if (count > FFR_INPUT_QUEUE_CAPACITY - session->inputQueueCount) {
        pthread_mutex_unlock(&session->inputMutex);
        return FFR_RESULT_INPUT_QUEUE_FULL;
    }

    for (size_t index = 0U; index < count; index += 1U) {
        const FFRQueuedInput *event = &events[index];
        if (event->type == FFR_QUEUED_INPUT_POINTER_MOVE &&
            session->inputQueueCount > 0U) {
            const size_t tail = (session->inputQueueHead + session->inputQueueCount - 1U) %
                                FFR_INPUT_QUEUE_CAPACITY;
            if (session->inputQueue[tail].type == FFR_QUEUED_INPUT_POINTER_MOVE) {
                session->inputQueue[tail] = *event;
                continue;
            }
        }
        const size_t tail = (session->inputQueueHead + session->inputQueueCount) %
                            FFR_INPUT_QUEUE_CAPACITY;
        session->inputQueue[tail] = *event;
        session->inputQueueCount += 1U;
    }
    (void)SetEvent(session->inputEvent);
    pthread_mutex_unlock(&session->inputMutex);
    return FFR_RESULT_OK;
}

FFRResult FFRSessionSendScanCode(FFRSession *session,
                                 uint32_t scanCode,
                                 bool down,
                                 bool repeat)
{
    if (scanCode == RDP_SCANCODE_UNKNOWN || (scanCode & ~0x01FFU) != 0U ||
        (!down && repeat)) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    const FFRQueuedInput event = {
        .type = FFR_QUEUED_INPUT_SCAN_CODE,
        .scanCode = scanCode,
        .down = down,
        .repeat = repeat,
    };
    return FFREnqueueInput(session, &event, 1U, false);
}

FFRResult FFRSessionSendUnicode(FFRSession *session,
                                const uint16_t *utf16CodeUnits,
                                size_t length)
{
    if (utf16CodeUnits == NULL || length == 0U || length > 64U) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    FFRQueuedInput events[64] = { 0 };
    for (size_t index = 0U; index < length; index += 1U) {
        if (utf16CodeUnits[index] == 0U) {
            return FFR_RESULT_INVALID_ARGUMENT;
        }
        events[index].type = FFR_QUEUED_INPUT_UNICODE;
        events[index].codeUnit = utf16CodeUnits[index];
    }
    return FFREnqueueInput(session, events, length, false);
}

FFRResult FFRSessionSendPointerMove(FFRSession *session, uint16_t x, uint16_t y)
{
    const FFRQueuedInput event = {
        .type = FFR_QUEUED_INPUT_POINTER_MOVE,
        .x = x,
        .y = y,
    };
    return FFREnqueueInput(session, &event, 1U, false);
}

FFRResult FFRSessionSendPointerButton(FFRSession *session,
                                      FFRPointerButton button,
                                      bool down,
                                      uint16_t x,
                                      uint16_t y)
{
    if (button < FFR_POINTER_BUTTON_LEFT || button > FFR_POINTER_BUTTON_X2) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    const FFRQueuedInput event = {
        .type = FFR_QUEUED_INPUT_POINTER_BUTTON,
        .x = x,
        .y = y,
        .button = button,
        .down = down,
    };
    return FFREnqueueInput(session, &event, 1U, false);
}

FFRResult FFRSessionSendPointerWheel(FFRSession *session,
                                     int16_t delta,
                                     bool horizontal,
                                     uint16_t x,
                                     uint16_t y)
{
    if (delta == 0 || delta < -255 || delta > 255) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    const FFRQueuedInput event = {
        .type = FFR_QUEUED_INPUT_POINTER_WHEEL,
        .x = x,
        .y = y,
        .wheelDelta = delta,
        .horizontal = horizontal,
    };
    return FFREnqueueInput(session, &event, 1U, false);
}

FFRResult FFRSessionSynchronizeLocks(FFRSession *session,
                                     bool capsLock,
                                     bool numLock,
                                     bool scrollLock)
{
    uint32_t flags = 0U;
    if (capsLock) {
        flags |= KBD_SYNC_CAPS_LOCK;
    }
    if (numLock) {
        flags |= KBD_SYNC_NUM_LOCK;
    }
    if (scrollLock) {
        flags |= KBD_SYNC_SCROLL_LOCK;
    }
    const FFRQueuedInput event = {
        .type = FFR_QUEUED_INPUT_SYNCHRONIZE,
        .toggleFlags = flags,
    };
    return FFREnqueueInput(session, &event, 1U, false);
}

FFRResult FFRSessionReleaseAllInput(FFRSession *session)
{
    const FFRQueuedInput event = { .type = FFR_QUEUED_INPUT_RELEASE_ALL };
    return FFREnqueueInput(session, &event, 1U, true);
}

FFRResult FFRSessionRequestResize(FFRSession *session, uint32_t width, uint32_t height)
{
    const FFRMonitorLayout monitor = {
        .left = 0,
        .top = 0,
        .width = width,
        .height = height,
        .desktopScaleFactor = 0,
        .deviceScaleFactor = 0,
        .primary = true,
    };
    return FFRSessionRequestMonitorLayout(session, &monitor, 1U);
}

FFRResult FFRSessionRequestMonitorLayout(FFRSession *session,
                                         const FFRMonitorLayout *monitors,
                                         size_t monitorCount)
{
    if (!FFRValidateMonitorLayout(monitors, monitorCount)) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    FFRQueuedInput event = { .type = FFR_QUEUED_INPUT_RESIZE };
    event.monitorCount = monitorCount;
    memcpy(event.monitors, monitors, monitorCount * sizeof(FFRMonitorLayout));
    return FFREnqueueInput(session, &event, 1U, false);
}

FFRResult FFRSessionPublishClipboardText(FFRSession *session,
                                         const uint16_t *utf16CodeUnits,
                                         size_t length)
{
    enum { FFR_MAX_CLIPBOARD_TEXT_CODE_UNITS = ((1024 * 1024) / 2) - 1 };
    if (session == NULL || length > FFR_MAX_CLIPBOARD_TEXT_CODE_UNITS ||
        (length > 0U && utf16CodeUnits == NULL)) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    if (!atomic_load_explicit(&session->inputEnabled, memory_order_acquire)) {
        return FFR_RESULT_INVALID_STATE;
    }
    for (size_t index = 0U; index < length; index += 1U) {
        if (utf16CodeUnits[index] == 0U) {
            return FFR_RESULT_INVALID_ARGUMENT;
        }
    }

    uint16_t *copy = NULL;
    if (length > 0U) {
        if (length > (SIZE_MAX / sizeof(uint16_t)) - 1U) {
            return FFR_RESULT_INVALID_ARGUMENT;
        }
        copy = calloc(length + 1U, sizeof(uint16_t));
        if (copy == NULL) {
            return FFR_RESULT_ALLOCATION_FAILED;
        }
        memcpy(copy, utf16CodeUnits, length * sizeof(uint16_t));
    }

    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        free(copy);
        return FFR_RESULT_INVALID_STATE;
    }
    free(session->localClipboardUtf16);
    session->localClipboardUtf16 = copy;
    session->localClipboardLength = length;
    pthread_mutex_unlock(&session->clipboardMutex);

    const FFRQueuedInput event = { .type = FFR_QUEUED_INPUT_CLIPBOARD_TEXT };
    return FFREnqueueInput(session, &event, 1U, false);
}

static uint16_t FFRPointerButtonBit(FFRPointerButton button)
{
    return (uint16_t)(1U << ((unsigned int)button - 1U));
}

static bool FFRSendPointerButton(rdpInput *input,
                                 FFRPointerButton button,
                                 bool down,
                                 uint16_t x,
                                 uint16_t y)
{
    uint16_t flags = down ? PTR_FLAGS_DOWN : 0U;
    switch (button) {
    case FFR_POINTER_BUTTON_LEFT:
        flags |= PTR_FLAGS_BUTTON1;
        return freerdp_input_send_mouse_event(input, flags, x, y);
    case FFR_POINTER_BUTTON_RIGHT:
        flags |= PTR_FLAGS_BUTTON2;
        return freerdp_input_send_mouse_event(input, flags, x, y);
    case FFR_POINTER_BUTTON_MIDDLE:
        flags |= PTR_FLAGS_BUTTON3;
        return freerdp_input_send_mouse_event(input, flags, x, y);
    case FFR_POINTER_BUTTON_X1:
        flags = (down ? PTR_XFLAGS_DOWN : 0U) | PTR_XFLAGS_BUTTON1;
        return freerdp_input_send_extended_mouse_event(input, flags, x, y);
    case FFR_POINTER_BUTTON_X2:
        flags = (down ? PTR_XFLAGS_DOWN : 0U) | PTR_XFLAGS_BUTTON2;
        return freerdp_input_send_extended_mouse_event(input, flags, x, y);
    default:
        return false;
    }
}

void FFRReleasePressedInputOnOwnerThread(FFRSession *session)
{
    if (session == NULL || session->instance == NULL ||
        session->instance->context == NULL || session->instance->context->input == NULL) {
        return;
    }
    rdpInput *input = session->instance->context->input;
    for (uint32_t scanCode = 1U; scanCode < 512U; scanCode += 1U) {
        if (session->pressedScanCodes[scanCode]) {
            (void)freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, scanCode);
            session->pressedScanCodes[scanCode] = false;
        }
    }
    for (FFRPointerButton button = FFR_POINTER_BUTTON_LEFT;
         button <= FFR_POINTER_BUTTON_X2;
         button = (FFRPointerButton)((int)button + 1)) {
        const uint16_t bit = FFRPointerButtonBit(button);
        if ((session->pressedPointerButtons & bit) != 0U) {
            (void)FFRSendPointerButton(input, button, false,
                                       session->lastPointerX, session->lastPointerY);
            session->pressedPointerButtons &= (uint16_t)~bit;
        }
    }
}

static bool FFRProcessInputEvent(FFRSession *session, const FFRQueuedInput *event)
{
    rdpInput *input = session->instance->context->input;
    switch (event->type) {
    case FFR_QUEUED_INPUT_SCAN_CODE: {
        const bool sent = freerdp_input_send_keyboard_event_ex(
            input, event->down, event->repeat, event->scanCode);
        if (sent) {
            session->pressedScanCodes[event->scanCode] = event->down;
        }
        return sent;
    }
    case FFR_QUEUED_INPUT_UNICODE:
        return freerdp_input_send_unicode_keyboard_event(input, 0U, event->codeUnit) &&
               freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_RELEASE,
                                                         event->codeUnit);
    case FFR_QUEUED_INPUT_POINTER_MOVE:
        session->lastPointerX = event->x;
        session->lastPointerY = event->y;
        return freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, event->x, event->y);
    case FFR_QUEUED_INPUT_POINTER_BUTTON: {
        session->lastPointerX = event->x;
        session->lastPointerY = event->y;
        const bool sent = FFRSendPointerButton(input, event->button, event->down,
                                               event->x, event->y);
        if (sent) {
            const uint16_t bit = FFRPointerButtonBit(event->button);
            if (event->down) {
                session->pressedPointerButtons |= bit;
            } else {
                session->pressedPointerButtons &= (uint16_t)~bit;
            }
        }
        return sent;
    }
    case FFR_QUEUED_INPUT_POINTER_WHEEL: {
        const uint16_t magnitude = (uint16_t)(event->wheelDelta < 0
            ? -event->wheelDelta : event->wheelDelta);
        uint16_t flags = event->horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
        if (event->wheelDelta < 0) {
            flags |= PTR_FLAGS_WHEEL_NEGATIVE;
            flags |= (uint16_t)((0x100U - magnitude) & WheelRotationMask);
        } else {
            flags |= magnitude & WheelRotationMask;
        }
        session->lastPointerX = event->x;
        session->lastPointerY = event->y;
        return freerdp_input_send_mouse_event(input, flags, event->x, event->y);
    }
    case FFR_QUEUED_INPUT_SYNCHRONIZE:
        return freerdp_input_send_focus_in_event(input, (uint16_t)event->toggleFlags) &&
               freerdp_input_send_synchronize_event(input, event->toggleFlags);
    case FFR_QUEUED_INPUT_RELEASE_ALL:
        FFRReleasePressedInputOnOwnerThread(session);
        return true;
    case FFR_QUEUED_INPUT_RESIZE:
        memcpy(session->pendingMonitorLayout, event->monitors,
               event->monitorCount * sizeof(FFRMonitorLayout));
        session->pendingMonitorCount = event->monitorCount;
        session->hasPendingResize = true;
        return FFRSendPendingResize(session);
    case FFR_QUEUED_INPUT_CLIPBOARD_TEXT:
        return FFRSendClipboardFormatList(session);
    default:
        return false;
    }
}

bool FFRProcessPendingInput(FFRSession *session)
{
    if (session == NULL || !FFRSessionIsOwnedByCurrentThread(session) ||
        session->instance == NULL || session->instance->context == NULL ||
        session->instance->context->input == NULL) {
        return false;
    }

    bool result = true;
    for (;;) {
        if (pthread_mutex_lock(&session->inputMutex) != 0) {
            return false;
        }
        if (session->inputQueueCount == 0U) {
            (void)ResetEvent(session->inputEvent);
            pthread_mutex_unlock(&session->inputMutex);
            break;
        }
        const FFRQueuedInput event = session->inputQueue[session->inputQueueHead];
        session->inputQueueHead = (session->inputQueueHead + 1U) % FFR_INPUT_QUEUE_CAPACITY;
        session->inputQueueCount -= 1U;
        pthread_mutex_unlock(&session->inputMutex);

        if (!FFRProcessInputEvent(session, &event)) {
            result = false;
        }
    }
    return result;
}

FFRResult FFRSessionConfigure(FFRSession *session,
                              const FFRConnectionSettings *settings)
{
    if (session == NULL || settings == NULL ||
        !FFRStringIsValid(settings->hostname, FFR_MAX_HOSTNAME_LENGTH, false) ||
        !FFRStringIsValid(settings->username, FFR_MAX_USERNAME_LENGTH, false) ||
        !FFRStringIsValid(settings->domain, FFR_MAX_DOMAIN_LENGTH, true) ||
        !FFRStringIsValid(settings->password, FFR_MAX_PASSWORD_LENGTH, true) ||
        !FFRStringIsValid(settings->certificateStorePath,
                          FFR_MAX_CERTIFICATE_STORE_PATH_LENGTH, false) ||
        !FFROptionalStringIsValid(settings->redirectedDirectoryPath,
                                  FFR_MAX_REDIRECTED_DIRECTORY_PATH_LENGTH) ||
        !FFROptionalPossiblyEmptyStringIsValid(
            settings->microphoneDeviceName,
            FFR_MAX_MICROPHONE_DEVICE_NAME_LENGTH) ||
        !FFROptionalStringIsValid(settings->gatewayHostname,
                                  FFR_MAX_GATEWAY_HOSTNAME_LENGTH) ||
        !FFROptionalStringIsValid(settings->remoteAppProgram,
                                  FFR_MAX_REMOTE_APP_FIELD_LENGTH) ||
        !FFROptionalPossiblyEmptyStringIsValid(
            settings->remoteAppArguments, FFR_MAX_REMOTE_APP_FIELD_LENGTH) ||
        !FFROptionalPossiblyEmptyStringIsValid(
            settings->remoteAppWorkingDirectory, FFR_MAX_REMOTE_APP_FIELD_LENGTH) ||
        settings->port == 0U) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    const bool hasGateway = settings->gatewayHostname != NULL;
    const bool hasRemoteApp = settings->remoteAppProgram != NULL;
    const bool hasMicrophone = settings->microphoneRedirection;
    if (hasGateway) {
        if (settings->gatewayPort == 0U ||
            (!settings->gatewayUseSameCredentials &&
             (!FFRStringIsValid(settings->gatewayUsername,
                                FFR_MAX_GATEWAY_USERNAME_LENGTH, false) ||
              !FFRStringIsValid(settings->gatewayDomain,
                                FFR_MAX_GATEWAY_DOMAIN_LENGTH, true) ||
              !FFRStringIsValid(settings->gatewayPassword,
                                FFR_MAX_GATEWAY_PASSWORD_LENGTH, true)))) {
            return FFR_RESULT_INVALID_ARGUMENT;
        }
    }
    if (!FFRSessionIsOwnedByCurrentThread(session)) {
        return FFR_RESULT_THREAD_VIOLATION;
    }
    if (session->state != FFR_SESSION_STATE_CREATED &&
        session->state != FFR_SESSION_STATE_CONFIGURED) {
        return FFR_RESULT_INVALID_STATE;
    }

    rdpSettings *target = session->instance->context->settings;
    char resolvedRedirectedDirectory[PATH_MAX] = {0};
    if (!FFRResolveExistingDirectory(settings->redirectedDirectoryPath,
                                     resolvedRedirectedDirectory)) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    const bool hasRedirectedDirectory = settings->redirectedDirectoryPath != NULL;
    const BOOL updated =
        freerdp_settings_set_string(target, FreeRDP_ServerHostname, settings->hostname) &&
        freerdp_settings_set_uint32(target, FreeRDP_ServerPort, settings->port) &&
        freerdp_settings_set_string(target, FreeRDP_Username, settings->username) &&
        freerdp_settings_set_string(target, FreeRDP_Domain, settings->domain) &&
        freerdp_settings_set_string(target, FreeRDP_Password, settings->password) &&
        freerdp_settings_set_string(target, FreeRDP_ConfigPath,
                                    settings->certificateStorePath) &&
        freerdp_settings_set_bool(target, FreeRDP_TlsSecurity, TRUE) &&
        freerdp_settings_set_bool(target, FreeRDP_NlaSecurity, TRUE) &&
        freerdp_settings_set_bool(target, FreeRDP_RdpSecurity, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_IgnoreCertificate, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_AutoAcceptCertificate, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_CertificateCallbackPreferPEM, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_NetworkAutoDetect, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_SupportHeartbeatPdu, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_SupportMultitransport, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_SupportDynamicTimeZone, TRUE) &&
        freerdp_settings_set_uint32(target, FreeRDP_KeyboardLayout, 0U) &&
        freerdp_settings_set_uint32(target, FreeRDP_KeyboardType,
                                    WINPR_KBD_TYPE_IBM_ENHANCED) &&
        freerdp_settings_set_uint32(target, FreeRDP_KeyboardSubType, 0U) &&
        freerdp_settings_set_uint32(target, FreeRDP_KeyboardFunctionKey, 12U) &&
        freerdp_settings_set_bool(target, FreeRDP_DeviceRedirection,
                                  settings->audioPlayback || hasRedirectedDirectory) &&
        freerdp_settings_set_bool(target, FreeRDP_AudioPlayback,
                                  settings->audioPlayback) &&
        freerdp_settings_set_bool(target, FreeRDP_AudioCapture,
                                  hasMicrophone) &&
        freerdp_settings_set_bool(target, FreeRDP_RedirectDrives, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_RedirectHomeDrive, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_RedirectClipboard,
                                  settings->clipboardText) &&
        freerdp_settings_set_uint32(target, FreeRDP_ClipboardFeatureMask,
                                    settings->clipboardText
                                        ? (CLIPRDR_FLAG_LOCAL_TO_REMOTE |
                                           CLIPRDR_FLAG_REMOTE_TO_LOCAL)
                                        : 0U) &&
        freerdp_settings_set_bool(target, FreeRDP_SupportDynamicChannels,
                                  settings->dynamicResolution || hasMicrophone) &&
        freerdp_settings_set_bool(target, FreeRDP_SupportDisplayControl,
                                  settings->dynamicResolution) &&
        freerdp_settings_set_bool(target, FreeRDP_DynamicResolutionUpdate,
                                  settings->dynamicResolution) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayEnabled, hasGateway) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayBypassLocal, FALSE) &&
        freerdp_settings_set_uint32(target, FreeRDP_GatewayUsageMethod,
                                    hasGateway ? TSC_PROXY_MODE_DIRECT
                                               : TSC_PROXY_MODE_NONE_DIRECT) &&
        freerdp_settings_set_uint32(target, FreeRDP_GatewayCredentialsSource,
                                    TSC_PROXY_CREDS_MODE_USERPASS) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayUseSameCredentials,
                                  hasGateway && settings->gatewayUseSameCredentials) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayRpcTransport, hasGateway) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayHttpTransport, hasGateway) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayUdpTransport, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayHttpUseWebsockets, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_GatewayArmTransport, FALSE) &&
        freerdp_settings_set_bool(target, FreeRDP_RemoteApplicationMode,
                                  hasRemoteApp) &&
        freerdp_settings_set_uint32(target, FreeRDP_RemoteApplicationExpandCmdLine,
                                    0U) &&
        freerdp_settings_set_uint32(target,
                                    FreeRDP_RemoteApplicationExpandWorkingDir,
                                    0U);
    if (!updated) {
        return FFR_RESULT_SETTINGS_FAILED;
    }
    if (hasGateway) {
        const BOOL gatewayUpdated =
            freerdp_settings_set_string(target, FreeRDP_GatewayHostname,
                                        settings->gatewayHostname) &&
            freerdp_settings_set_uint32(target, FreeRDP_GatewayPort,
                                        settings->gatewayPort);
        if (!gatewayUpdated) {
            return FFR_RESULT_SETTINGS_FAILED;
        }
        if (!settings->gatewayUseSameCredentials) {
            const BOOL gatewayCredentialsUpdated =
                freerdp_settings_set_string(target, FreeRDP_GatewayUsername,
                                            settings->gatewayUsername) &&
                freerdp_settings_set_string(target, FreeRDP_GatewayDomain,
                                            settings->gatewayDomain) &&
                freerdp_settings_set_string(target, FreeRDP_GatewayPassword,
                                            settings->gatewayPassword);
            if (!gatewayCredentialsUpdated) {
                return FFR_RESULT_SETTINGS_FAILED;
            }
        }
    }
    if (hasRedirectedDirectory) {
        const char *driveParams[] = {"drive", "Farframe", resolvedRedirectedDirectory};
        if (!freerdp_client_add_device_channel(target, 3U, driveParams)) {
            return FFR_RESULT_SETTINGS_FAILED;
        }
    }
    if (hasRemoteApp) {
        const BOOL remoteAppUpdated =
            freerdp_settings_set_string(target, FreeRDP_RemoteApplicationProgram,
                                        settings->remoteAppProgram) &&
            freerdp_settings_set_string(target, FreeRDP_RemoteApplicationCmdLine,
                                        settings->remoteAppArguments != NULL
                                            ? settings->remoteAppArguments
                                            : "") &&
            freerdp_settings_set_string(target,
                                        FreeRDP_RemoteApplicationWorkingDir,
                                        settings->remoteAppWorkingDirectory != NULL
                                            ? settings->remoteAppWorkingDirectory
                                            : "");
        if (!remoteAppUpdated) {
            return FFR_RESULT_SETTINGS_FAILED;
        }
    }
    if (settings->dynamicResolution &&
        !FFRAddDynamicChannel(target, DISP_CHANNEL_NAME)) {
        return FFR_RESULT_SETTINGS_FAILED;
    }
    if (settings->clipboardText &&
        !FFRAddStaticChannel(target, CLIPRDR_SVC_CHANNEL_NAME)) {
        return FFR_RESULT_SETTINGS_FAILED;
    }
    if (settings->audioPlayback &&
        (!FFRAddStaticChannel(target, RDPSND_CHANNEL_NAME) ||
         !FFRAddDynamicChannel(target, RDPSND_CHANNEL_NAME))) {
        return FFR_RESULT_SETTINGS_FAILED;
    }
    if (hasMicrophone &&
        !FFRAddAudinChannel(target, settings->microphoneDeviceName)) {
        return FFR_RESULT_SETTINGS_FAILED;
    }
    if (hasRemoteApp && !FFRAddStaticChannel(target, RAIL_SVC_CHANNEL_NAME)) {
        return FFR_RESULT_SETTINGS_FAILED;
    }

    atomic_store_explicit(&session->cancellationRequested, false, memory_order_release);
    session->authenticationCallbacks = 0U;
    session->certificateRejected = false;
    session->certificateWasChanged = false;
    session->negotiatedSecurityProtocol = FFR_SECURITY_PROTOCOL_UNKNOWN;
    session->dynamicResolutionEnabled = settings->dynamicResolution;
    session->clipboardTextEnabled = settings->clipboardText;
    FFRClearClipboardState(session);
    session->displayControl = NULL;
    session->displayControlActivated = false;
    session->hasPendingResize = false;
    session->pendingResizeWidth = 0U;
    session->pendingResizeHeight = 0U;
    memset(session->pendingMonitorLayout, 0, sizeof(session->pendingMonitorLayout));
    session->pendingMonitorCount = 0U;
    session->instance->AuthenticateEx = FFRAuthenticate;
    session->instance->VerifyCertificateEx = FFRVerifyCertificate;
    session->instance->VerifyChangedCertificateEx = FFRVerifyChangedCertificate;
    /*
     * freerdp_connect() recreates context->channels immediately before the
     * protocol pre-connect phase. Loading addins here would populate the old
     * manager and then silently discard every channel. FreeRDP invokes this
     * callback after creating each replacement manager, including redirects.
     */
    session->instance->LoadChannels = FFRLoadChannels;
    session->state = FFR_SESSION_STATE_CONFIGURED;
    return FFR_RESULT_OK;
}

FFRResult FFRSessionConnect(FFRSession *session)
{
    if (session == NULL) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    if (!FFRSessionIsOwnedByCurrentThread(session)) {
        return FFR_RESULT_THREAD_VIOLATION;
    }
    if (session->state != FFR_SESSION_STATE_CONFIGURED) {
        return FFR_RESULT_INVALID_STATE;
    }

    session->state = FFR_SESSION_STATE_CONNECTING;
    atomic_store_explicit(&session->connectionActive, true, memory_order_release);
    FFREmitEvent(session, FFR_EVENT_RESOLVING, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);
    FFREmitEvent(session, FFR_EVENT_CONNECTING, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);

    if (!freerdp_connect(session->instance)) {
        const uint32_t nativeError = freerdp_get_last_error(session->instance->context);
        const bool cancelled =
            atomic_load_explicit(&session->cancellationRequested, memory_order_acquire) ||
            nativeError == FREERDP_ERROR_CONNECT_CANCELLED;
        FFRConnectionFailure failure = FFRMapConnectionFailure(nativeError);
        if (session->certificateRejected) {
            failure = session->certificateWasChanged
                ? FFR_CONNECTION_FAILURE_CERTIFICATE_CHANGED
                : FFR_CONNECTION_FAILURE_CERTIFICATE_REJECTED;
        } else if (cancelled) {
            failure = FFR_CONNECTION_FAILURE_CANCELLED;
        }
        const FFRResult result = cancelled ? FFR_RESULT_CANCELLED : FFR_RESULT_CONNECTION_FAILED;
        session->state = FFR_SESSION_STATE_FINISHED;
        atomic_store_explicit(&session->connectionActive, false, memory_order_release);
        FFREmitEvent(session, cancelled ? FFR_EVENT_DISCONNECTED : FFR_EVENT_FAILED,
                     result, failure, nativeError, NULL);
        return result;
    }

    const uint32_t selectedProtocol = freerdp_settings_get_uint32(
        session->instance->context->settings, FreeRDP_SelectedProtocol);
    session->negotiatedSecurityProtocol = FFRMapSecurityProtocol(selectedProtocol);
    session->state = FFR_SESSION_STATE_CONNECTED;
    atomic_store_explicit(&session->inputEnabled, true, memory_order_release);
    FFREmitEvent(session, FFR_EVENT_CONNECTED, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);

    FFRResult result = FFR_RESULT_OK;
    FFRConnectionFailure failure = FFR_CONNECTION_FAILURE_NONE;
    uint32_t nativeError = 0U;

    while (!atomic_load_explicit(&session->cancellationRequested, memory_order_acquire) &&
           !freerdp_shall_disconnect_context(session->instance->context)) {
        if (!FFRProcessPendingInput(session)) {
            result = FFR_RESULT_CONNECTION_FAILED;
            failure = FFR_CONNECTION_FAILURE_PROTOCOL;
            break;
        }
        if (!FFRSendPendingResize(session)) {
            result = FFR_RESULT_CONNECTION_FAILED;
            failure = FFR_CONNECTION_FAILURE_PROTOCOL;
            break;
        }

        HANDLE events[FFR_MAX_EVENT_HANDLES] = { 0 };
        const DWORD protocolCount = freerdp_get_event_handles(
            session->instance->context, events, FFR_MAX_EVENT_HANDLES - 1U);
        if (protocolCount == 0U || protocolCount >= FFR_MAX_EVENT_HANDLES) {
            result = FFR_RESULT_CONNECTION_FAILED;
            failure = FFR_CONNECTION_FAILURE_PROTOCOL;
            break;
        }
        events[protocolCount] = session->inputEvent;
        const DWORD count = protocolCount + 1U;

        const DWORD waitResult = WaitForMultipleObjects(count, events, FALSE, 100U);
        if (waitResult == WAIT_FAILED) {
            result = FFR_RESULT_CONNECTION_FAILED;
            failure = FFR_CONNECTION_FAILURE_PROTOCOL;
            break;
        }
        if (waitResult == WAIT_OBJECT_0 + protocolCount) {
            continue;
        }
        if (waitResult != WAIT_TIMEOUT &&
            !freerdp_check_event_handles(session->instance->context)) {
            nativeError = freerdp_get_last_error(session->instance->context);
            result = FFR_RESULT_CONNECTION_FAILED;
            failure = FFRMapConnectionFailure(nativeError);
            break;
        }
    }

    atomic_store_explicit(&session->inputEnabled, false, memory_order_release);
    (void)FFRProcessPendingInput(session);
    FFRReleasePressedInputOnOwnerThread(session);

    const bool cancelled =
        atomic_load_explicit(&session->cancellationRequested, memory_order_acquire);
    FFREmitEvent(session, FFR_EVENT_DISCONNECTING, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);
    (void)freerdp_disconnect(session->instance);
    session->state = FFR_SESSION_STATE_FINISHED;
    atomic_store_explicit(&session->connectionActive, false, memory_order_release);

    if (cancelled) {
        result = FFR_RESULT_CANCELLED;
        failure = FFR_CONNECTION_FAILURE_CANCELLED;
    }
    FFREmitEvent(session,
                 result == FFR_RESULT_CONNECTION_FAILED ? FFR_EVENT_FAILED : FFR_EVENT_DISCONNECTED,
                 result, failure, nativeError, NULL);
    return result;
}

FFRResult FFRSessionRequestCancellation(FFRSession *session)
{
    if (session == NULL) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }

    atomic_store_explicit(&session->cancellationRequested, true, memory_order_release);
    if (session->inputEvent != NULL) {
        (void)SetEvent(session->inputEvent);
    }
    if (pthread_mutex_lock(&session->decisionMutex) == 0) {
        pthread_cond_broadcast(&session->decisionCondition);
        pthread_mutex_unlock(&session->decisionMutex);
    }
    if (atomic_load_explicit(&session->connectionActive, memory_order_acquire) &&
        session->instance != NULL && session->instance->context != NULL) {
        (void)freerdp_abort_connect_context(session->instance->context);
    }
    return FFR_RESULT_OK;
}

FFRResult FFRSessionResolveCertificate(FFRSession *session,
                                       FFRCertificateDecision decision)
{
    if (session == NULL || decision < FFR_CERTIFICATE_REJECT ||
        decision > FFR_CERTIFICATE_ACCEPT_FOR_SESSION) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    if (pthread_mutex_lock(&session->decisionMutex) != 0) {
        return FFR_RESULT_INVALID_STATE;
    }
    if (!session->waitingForCertificate || session->certificateDecisionReady) {
        pthread_mutex_unlock(&session->decisionMutex);
        return FFR_RESULT_INVALID_STATE;
    }

    session->certificateDecision = decision;
    session->certificateDecisionReady = true;
    pthread_cond_broadcast(&session->decisionCondition);
    pthread_mutex_unlock(&session->decisionMutex);
    return FFR_RESULT_OK;
}

FFRSecurityProtocol FFRSessionNegotiatedSecurityProtocol(const FFRSession *session)
{
    return session == NULL ? FFR_SECURITY_PROTOCOL_UNKNOWN
                           : session->negotiatedSecurityProtocol;
}

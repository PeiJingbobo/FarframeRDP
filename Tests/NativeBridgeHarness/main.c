#include "FarframeRDPBridgeInternal.h"

#include <freerdp/channels/channels.h>
#include <freerdp/channels/audin.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/rdpsnd.h>
#include <freerdp/error.h>
#include <freerdp/rail.h>
#include <freerdp/settings.h>
#include <freerdp/settings_types.h>
#include "drive_file.h"
#include <winpr/string.h>

#include <assert.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct ThreadCheck {
    FFRSession **session;
    FFRResult result;
} ThreadCheck;

static void *DestroyFromWrongThread(void *context)
{
    ThreadCheck *check = context;
    check->result = FFRSessionDestroy(check->session);
    return NULL;
}

typedef struct GraphicsEvents {
    size_t desktopSizeEvents;
} GraphicsEvents;

static void RecordGraphicsEvent(FFRSession *session,
                                const FFRGraphicsEvent *event,
                                void *userContext)
{
    assert(session != NULL);
    assert(event != NULL);
    GraphicsEvents *events = userContext;
    if (event->type == FFR_GRAPHICS_EVENT_DESKTOP_SIZE) {
        assert(event->desktopWidth > 0U);
        assert(event->desktopHeight > 0U);
        assert(event->pixels == NULL);
        events->desktopSizeEvents += 1U;
    }
}

static void ValidateHostileDrivePaths(void)
{
    char rootTemplate[] = "/tmp/farframe-drive-root-XXXXXX";
    char outsideTemplate[] = "/tmp/farframe-drive-outside-XXXXXX";
    char *root = mkdtemp(rootTemplate);
    char *outside = mkdtemp(outsideTemplate);
    assert(root != NULL);
    assert(outside != NULL);

    char insidePath[PATH_MAX] = {0};
    char outsidePath[PATH_MAX] = {0};
    char linkPath[PATH_MAX] = {0};
    assert(snprintf(insidePath, sizeof(insidePath), "%s/inside.txt", root) > 0);
    assert(snprintf(outsidePath, sizeof(outsidePath), "%s/secret.txt", outside) > 0);
    assert(snprintf(linkPath, sizeof(linkPath), "%s/escape", root) > 0);
    FILE *inside = fopen(insidePath, "w");
    FILE *secret = fopen(outsidePath, "w");
    assert(inside != NULL);
    assert(secret != NULL);
    assert(fclose(inside) == 0);
    assert(fclose(secret) == 0);
    assert(symlink(outside, linkPath) == 0);

    WCHAR *base = ConvertUtf8ToWCharAlloc(root, NULL);
    WCHAR *valid = ConvertUtf8ToWCharAlloc("\\inside.txt", NULL);
    WCHAR *traversal = ConvertUtf8ToWCharAlloc("\\..\\secret.txt", NULL);
    WCHAR *escape = ConvertUtf8ToWCharAlloc("\\escape\\secret.txt", NULL);
    assert(base != NULL && valid != NULL && traversal != NULL && escape != NULL);

    DRIVE_FILE *file = drive_file_new(base, valid, (UINT32)_wcslen(valid), 1U,
                                      GENERIC_READ, FILE_OPEN, FILE_NON_DIRECTORY_FILE,
                                      0U, FILE_SHARE_READ);
    assert(file != NULL);
    assert(drive_file_free(file));
    assert(drive_file_new(base, traversal, (UINT32)_wcslen(traversal), 2U,
                          GENERIC_READ, FILE_OPEN, FILE_NON_DIRECTORY_FILE,
                          0U, FILE_SHARE_READ) == NULL);
    assert(drive_file_new(base, escape, (UINT32)_wcslen(escape), 3U,
                          GENERIC_READ, FILE_OPEN, FILE_NON_DIRECTORY_FILE,
                          0U, FILE_SHARE_READ) == NULL);

    const WCHAR embeddedNul[] = { L'\\', L'i', L'n', L'\0', L'x' };
    assert(drive_file_new(base, embeddedNul, 5U, 4U, GENERIC_READ, FILE_OPEN,
                          FILE_NON_DIRECTORY_FILE, 0U, FILE_SHARE_READ) == NULL);

    free(base);
    free(valid);
    free(traversal);
    free(escape);
    assert(unlink(linkPath) == 0);
    assert(unlink(insidePath) == 0);
    assert(unlink(outsidePath) == 0);
    assert(rmdir(root) == 0);
    assert(rmdir(outside) == 0);
}

int main(void)
{
    ValidateHostileDrivePaths();
    const uint16_t terminatedClipboard[] = { 'o', 'k', 0U };
    const uint16_t unterminatedClipboard[] = { 'n', 'o' };
    assert(FFRClipboardUTF16Length((const BYTE *)terminatedClipboard,
                                   sizeof(terminatedClipboard)) == 2U);
    assert(FFRClipboardUTF16Length((const BYTE *)unterminatedClipboard,
                                   sizeof(unterminatedClipboard)) == SIZE_MAX);
    assert(FFRClipboardUTF16Length((const BYTE *)terminatedClipboard, 1U) == SIZE_MAX);
    assert(FFRClipboardUTF16Length(NULL, sizeof(terminatedClipboard)) == SIZE_MAX);
    FFRClipboardFormatKind mappedClipboardKind = 0;
    const CLIPRDR_FORMAT remotePNG = {
        .formatId = 0xC9A5U,
        .formatName = "PNG",
    };
    assert(FFRClipboardRemoteFormat(&remotePNG, &mappedClipboardKind));
    assert(mappedClipboardKind == FFR_CLIPBOARD_FORMAT_PNG);
    const CLIPRDR_FORMAT untrustedNamedFormat = {
        .formatId = 0xC9A6U,
        .formatName = "image/unknown",
    };
    assert(!FFRClipboardRemoteFormat(&untrustedNamedFormat, &mappedClipboardKind));
    size_t validatedLength = 0U;
    assert(FFRValidateDesktopGeometry(1920U, 1080U, 7680U, &validatedLength));
    assert(validatedLength == 8294400U);
    assert(!FFRValidateDesktopGeometry(0U, 1080U, 7680U, &validatedLength));
    assert(!FFRValidateDesktopGeometry(16385U, 1U, 65540U, &validatedLength));
    assert(!FFRValidateDesktopGeometry(1024U, 768U, 4095U, &validatedLength));
    assert(!FFRValidateDesktopGeometry(16384U, 4097U, 65536U, &validatedLength));
    assert(!FFRValidateDesktopGeometry(1024U, 768U, 4096U, NULL));

    assert(FFRValidateDirtyRectangle(0, 0, 1920, 1080, 1920U, 1080U));
    assert(FFRValidateDirtyRectangle(1919, 1079, 1, 1, 1920U, 1080U));
    assert(!FFRValidateDirtyRectangle(-1, 0, 1, 1, 1920U, 1080U));
    assert(!FFRValidateDirtyRectangle(1919, 0, 2, 1, 1920U, 1080U));
    assert(!FFRValidateDirtyRectangle(INT32_MAX, INT32_MAX, INT32_MAX, INT32_MAX,
                                      1920U, 1080U));

    assert(FFRValidateCursorGeometry(512U, 512U, 511U, 511U, &validatedLength));
    assert(validatedLength == 1048576U);
    assert(!FFRValidateCursorGeometry(513U, 1U, 0U, 0U, &validatedLength));
    assert(!FFRValidateCursorGeometry(32U, 32U, 32U, 0U, &validatedLength));
    assert(!FFRValidateCursorGeometry(32U, 32U, 0U, 32U, &validatedLength));
    assert(!FFRValidateCursorGeometry(UINT32_MAX, UINT32_MAX, 0U, 0U,
                                      &validatedLength));

    assert(FFRBridgeABIVersion() == 15U);
    assert(strcmp(FFRFreeRDPVersion(), "3.30.0") == 0);
    assert(strlen(FFRFreeRDPBuildRevision()) > 0);
    assert(FFRBridgeLiveSessionCount() == 0U);
    assert(FFRMapConnectionFailure(FREERDP_ERROR_TLS_CONNECT_FAILED) ==
           FFR_CONNECTION_FAILURE_TLS);
    assert(FFRMapConnectionFailure(FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED) ==
           FFR_CONNECTION_FAILURE_SECURITY_NEGOTIATION);
    assert(FFRMapConnectionFailure(FREERDP_ERROR_AUTHENTICATION_FAILED) ==
           FFR_CONNECTION_FAILURE_AUTHENTICATION);
    assert(FFRMapConnectionFailure(FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED) ==
           FFR_CONNECTION_FAILURE_SERVER_REFUSED);
    assert(FFRMapConnectionFailure(UINT32_MAX) == FFR_CONNECTION_FAILURE_PROTOCOL);

    for (size_t index = 0; index < 10U; index += 1) {
        FFRSession *session = NULL;
        assert(FFRSessionCreate(NULL, NULL, &session) == FFR_RESULT_OK);
        assert(session != NULL);
        assert(FFRSessionOwnsCurrentThread(session));
        assert(session->instance->PostConnect != NULL);
        assert(session->instance->PostDisconnect != NULL);
        GraphicsEvents graphicsEvents = { 0 };
        assert(FFRSessionSetGraphicsEventCallback(session, RecordGraphicsEvent,
                                                  &graphicsEvents) == FFR_RESULT_OK);
        assert(session->instance->context->gdi == NULL);
        assert(session->instance->context->cache == NULL);
        assert(session->instance->PostConnect(session->instance));
        assert(session->instance->context->gdi != NULL);
        assert(session->instance->context->cache != NULL);
        assert(graphicsEvents.desktopSizeEvents == 1U);
        session->instance->PostDisconnect(session->instance);
        assert(session->instance->context->gdi == NULL);
        assert(session->instance->context->cache == NULL);
        assert(FFRSessionNegotiatedSecurityProtocol(session) ==
               FFR_SECURITY_PROTOCOL_UNKNOWN);
        assert(!FFRSessionIsCancellationRequested(session));
        assert(FFRSessionSendScanCode(session, 0x1EU, true, false) ==
               FFR_RESULT_INVALID_STATE);
        assert(FFRSessionRequestResize(session, 1024U, 768U) ==
               FFR_RESULT_INVALID_STATE);
        assert(FFRSessionRequestResize(session, 199U, 768U) ==
               FFR_RESULT_INVALID_ARGUMENT);
        assert(FFRSessionRequestResize(session, 1024U, 8193U) ==
               FFR_RESULT_INVALID_ARGUMENT);
        session->state = FFR_SESSION_STATE_CONNECTED;
        atomic_store_explicit(&session->inputEnabled, true, memory_order_release);
        const uint16_t embeddedClipboardNul[] = { 'a', 0U, 'b' };
        assert(FFRSessionPublishClipboardText(session, embeddedClipboardNul, 3U) ==
               FFR_RESULT_INVALID_ARGUMENT);
        const uint16_t harmlessClipboardUnit = 'a';
        assert(FFRSessionPublishClipboardText(session, &harmlessClipboardUnit,
                                              ((1024U * 1024U) / 2U)) ==
               FFR_RESULT_INVALID_ARGUMENT);
        const uint16_t clipboardWireText[] = { 'o', 'k', 0U };
        const FFRClipboardPayload clipboardPayload = {
            .kind = FFR_CLIPBOARD_FORMAT_UNICODE_TEXT,
            .bytes = (const uint8_t *)clipboardWireText,
            .length = sizeof(clipboardWireText),
        };
        assert(FFRSessionPublishClipboardOffer(session, 10U, &clipboardPayload, 1U) ==
               FFR_RESULT_OK);
        assert(session->localClipboardGeneration == 10U);
        assert(session->localClipboardPayloadCount == 1U);
        assert(session->inputQueueCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].type ==
               FFR_QUEUED_INPUT_CLIPBOARD_OFFER);
        assert(FFRSessionPublishClipboardOffer(session, 10U, &clipboardPayload, 1U) ==
               FFR_RESULT_INVALID_ARGUMENT);
        const FFRClipboardPayload duplicatePayloads[] = {
            clipboardPayload,
            clipboardPayload,
        };
        assert(FFRSessionPublishClipboardOffer(session, 11U, duplicatePayloads, 2U) ==
               FFR_RESULT_INVALID_ARGUMENT);
        const FFRClipboardPayload unterminatedPayload = {
            .kind = FFR_CLIPBOARD_FORMAT_UNICODE_TEXT,
            .bytes = (const uint8_t *)unterminatedClipboard,
            .length = sizeof(unterminatedClipboard),
        };
        assert(FFRSessionPublishClipboardOffer(session, 11U, &unterminatedPayload, 1U) ==
               FFR_RESULT_INVALID_ARGUMENT);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        session->remoteClipboardGeneration = 5U;
        assert(FFRSessionRequestClipboardData(session, 5U, CF_UNICODETEXT,
                                              FFR_CLIPBOARD_FORMAT_UNICODE_TEXT) ==
               FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].type ==
               FFR_QUEUED_INPUT_CLIPBOARD_REQUEST);
        assert(session->inputQueue[session->inputQueueHead].clipboardGeneration == 5U);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        session->localFileRequests[0] = (FFRClipboardLocalFileRequest) {
            .active = true,
            .requestId = 77U,
            .kind = FFR_CLIPBOARD_FILE_REQUEST_SIZE,
            .requestedBytes = sizeof(uint64_t),
        };
        const uint64_t localFileSize = 42U;
        assert(FFRSessionRespondLocalFileRequest(
                   session, 77U, true, (const uint8_t *)&localFileSize,
                   sizeof(localFileSize)) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].type ==
               FFR_QUEUED_INPUT_CLIPBOARD_FILE_RESPONSE);
        assert(session->inputQueue[session->inputQueueHead].fileRequestId == 77U);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        free(session->localFileRequests[0].responseBytes);
        memset(&session->localFileRequests[0], 0,
               sizeof(session->localFileRequests[0]));
        assert(FFRSessionRequestRemoteFileContents(
                   session, 5U, 9U, 0U, FFR_CLIPBOARD_FILE_REQUEST_RANGE,
                   0U, FFR_MAX_CLIPBOARD_FILE_RANGE_BYTES + 1U) ==
               FFR_RESULT_INVALID_ARGUMENT);
        assert(FFRSessionRequestRemoteFileContents(
                   session, 5U, 9U, 0U, FFR_CLIPBOARD_FILE_REQUEST_SIZE,
                   0U, 0U) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].type ==
               FFR_QUEUED_INPUT_CLIPBOARD_FILE_REQUEST);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        assert(FFRSessionSendScanCode(session, 0x1EU, true, false) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        assert(FFRSessionRequestResize(session, 1024U, 768U) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].type ==
               FFR_QUEUED_INPUT_RESIZE);
        assert(session->inputQueue[session->inputQueueHead].monitorCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].monitors[0].width == 1024U);
        assert(session->inputQueue[session->inputQueueHead].monitors[0].height == 768U);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        assert(FFRSessionSendPointerMove(session, 10U, 20U) == FFR_RESULT_OK);
        assert(FFRSessionSendPointerMove(session, 11U, 21U) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].type ==
               FFR_QUEUED_INPUT_POINTER_MOVE);
        assert(session->inputQueue[session->inputQueueHead].x == 11U);
        assert(session->inputQueue[session->inputQueueHead].y == 21U);
        assert(FFRSessionReleaseAllInput(session) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        assert(session->inputQueue[session->inputQueueHead].type ==
               FFR_QUEUED_INPUT_RELEASE_ALL);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        for (size_t inputIndex = 0U; inputIndex < FFR_INPUT_QUEUE_CAPACITY;
             inputIndex += 1U) {
            assert(FFRSessionSendScanCode(session, 0x1EU, true, true) == FFR_RESULT_OK);
        }
        assert(FFRSessionSendScanCode(session, 0x1EU, true, true) ==
               FFR_RESULT_INPUT_QUEUE_FULL);
        assert(FFRSessionReleaseAllInput(session) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        atomic_store_explicit(&session->inputEnabled, false, memory_order_release);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        session->state = FFR_SESSION_STATE_CREATED;

        const FFRConnectionSettings settings = {
            .hostname = "example.invalid",
            .port = 3389,
            .username = "test-user",
            .domain = "",
            .password = "",
            .certificateStorePath = "/tmp/farframe-rdp-native-tests",
            .dynamicResolution = true,
            .clipboardText = true,
            .clipboardFiles = true,
            .audioPlayback = true,
            .microphoneRedirection = true,
            .microphoneDeviceName = "",
            .redirectedDirectoryPath = "/tmp",
            .gatewayHostname = "gateway.example",
            .gatewayPort = 443,
            .gatewayUseSameCredentials = true,
            .gatewayUsername = NULL,
            .gatewayDomain = NULL,
            .gatewayPassword = NULL,
            .remoteAppProgram = "||notepad",
            .remoteAppArguments = "",
            .remoteAppWorkingDirectory = "",
        };
        assert(FFRSessionConfigure(session, &settings) == FFR_RESULT_OK);
        assert(session->instance->LoadChannels != NULL);
        assert(session->instance->LoadChannels(session->instance));
        StaticClientChannelStats *channelStats = freerdp_channels_client_stats(
            session->instance->context->channels);
        assert(channelStats != NULL);
        assert(channelStats->count >= 3U);
        freerdp_channel_client_stats_free(channelStats);
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_RedirectClipboard));
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_ClipboardFeatureMask) ==
               (CLIPRDR_FLAG_LOCAL_TO_REMOTE |
                CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES |
                CLIPRDR_FLAG_REMOTE_TO_LOCAL |
                CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES));
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_AudioPlayback));
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_AudioCapture));
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_DeviceRedirection));
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_SupportDynamicTimeZone));
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_KeyboardLayout) == 0U);
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_KeyboardType) == 4U);
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_KeyboardSubType) == 0U);
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_KeyboardFunctionKey) == 12U);
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_DeviceArraySize) == 32U);
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_DeviceCount) == 1U);
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_GatewayEnabled));
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_GatewayUsageMethod) ==
               TSC_PROXY_MODE_DIRECT);
        assert(strcmp(freerdp_settings_get_string(session->instance->context->settings,
                                                  FreeRDP_GatewayHostname),
                      "gateway.example") == 0);
        assert(freerdp_settings_get_uint32(session->instance->context->settings,
                                           FreeRDP_GatewayPort) == 443U);
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_GatewayUseSameCredentials));
        assert(freerdp_settings_get_bool(session->instance->context->settings,
                                         FreeRDP_RemoteApplicationMode));
        assert(strcmp(freerdp_settings_get_string(session->instance->context->settings,
                                                  FreeRDP_RemoteApplicationProgram),
                      "||notepad") == 0);
        assert(strcmp(freerdp_settings_get_string(session->instance->context->settings,
                                                  FreeRDP_RemoteApplicationCmdLine),
                      "") == 0);
        assert(freerdp_dynamic_channel_collection_find(
                   session->instance->context->settings,
                   DISP_CHANNEL_NAME) != NULL);
        assert(freerdp_static_channel_collection_find(
                   session->instance->context->settings,
                   CLIPRDR_SVC_CHANNEL_NAME) != NULL);
        assert(freerdp_static_channel_collection_find(
                   session->instance->context->settings,
                   RDPSND_CHANNEL_NAME) != NULL);
        assert(freerdp_dynamic_channel_collection_find(
                   session->instance->context->settings,
                   RDPSND_CHANNEL_NAME) != NULL);
        assert(freerdp_dynamic_channel_collection_find(
                   session->instance->context->settings,
                   AUDIN_CHANNEL_NAME) != NULL);
        assert(freerdp_static_channel_collection_find(
                   session->instance->context->settings,
                   RAIL_SVC_CHANNEL_NAME) != NULL);
        RDPDR_DEVICE *drive = freerdp_device_collection_find_type(
            session->instance->context->settings,
            RDPDR_DTYP_FILESYSTEM);
        assert(drive != NULL);
        assert(strcmp(drive->Name, "Farframe") == 0);
        const RDPDR_DRIVE *redirectedDrive = (const RDPDR_DRIVE *)drive;
        assert(strcmp(redirectedDrive->Path, "/private/tmp") == 0 ||
               strcmp(redirectedDrive->Path, "/tmp") == 0);
        assert(FFRSessionResolveCertificate(session, FFR_CERTIFICATE_REJECT) ==
               FFR_RESULT_INVALID_STATE);
        const FFRMonitorLayout monitors[] = {
            {
                .left = 0,
                .top = 0,
                .width = 1024,
                .height = 768,
                .desktopScaleFactor = 100,
                .deviceScaleFactor = 100,
                .primary = true,
            },
            {
                .left = 1024,
                .top = 0,
                .width = 1024,
                .height = 768,
                .desktopScaleFactor = 100,
                .deviceScaleFactor = 100,
                .primary = false,
            },
        };
        atomic_store_explicit(&session->inputEnabled, true, memory_order_release);
        assert(FFRSessionRequestMonitorLayout(session, monitors, 2U) == FFR_RESULT_OK);
        assert(session->inputQueueCount == 1U);
        const FFRQueuedInput layoutEvent = session->inputQueue[session->inputQueueHead];
        assert(layoutEvent.monitorCount == 2U);
        assert(layoutEvent.monitors[0].primary);
        assert(layoutEvent.monitors[1].left == 1024);
        session->inputQueueHead = 0U;
        session->inputQueueCount = 0U;
        atomic_store_explicit(&session->inputEnabled, false, memory_order_release);
        assert(FFRSessionRequestCancellation(session) == FFR_RESULT_OK);
        assert(FFRSessionIsCancellationRequested(session));
        assert(FFRSessionDestroy(&session) == FFR_RESULT_OK);
        assert(session == NULL);

        FFRSession *disabledSession = NULL;
        assert(FFRSessionCreate(NULL, NULL, &disabledSession) == FFR_RESULT_OK);
        assert(disabledSession != NULL);

        const FFRConnectionSettings clipboardDisabledSettings = {
            .hostname = "example.invalid",
            .port = 3389,
            .username = "test-user",
            .domain = "",
            .password = "",
            .certificateStorePath = "/tmp/farframe-rdp-native-tests",
            .dynamicResolution = true,
            .clipboardText = false,
            .audioPlayback = false,
            .microphoneRedirection = false,
            .microphoneDeviceName = NULL,
            .redirectedDirectoryPath = NULL,
            .gatewayHostname = NULL,
            .gatewayPort = 0,
            .gatewayUseSameCredentials = true,
            .gatewayUsername = NULL,
            .gatewayDomain = NULL,
            .gatewayPassword = NULL,
            .remoteAppProgram = NULL,
            .remoteAppArguments = NULL,
            .remoteAppWorkingDirectory = NULL,
        };
        assert(FFRSessionConfigure(disabledSession, &clipboardDisabledSettings) ==
               FFR_RESULT_OK);
        assert(!freerdp_settings_get_bool(disabledSession->instance->context->settings,
                                          FreeRDP_RedirectClipboard));
        assert(freerdp_settings_get_uint32(disabledSession->instance->context->settings,
                                           FreeRDP_ClipboardFeatureMask) == 0U);
        assert(!freerdp_settings_get_bool(disabledSession->instance->context->settings,
                                          FreeRDP_AudioPlayback));
        assert(!freerdp_settings_get_bool(disabledSession->instance->context->settings,
                                          FreeRDP_DeviceRedirection));
        assert(freerdp_settings_get_uint32(disabledSession->instance->context->settings,
                                           FreeRDP_DeviceCount) == 0U);
        assert(!freerdp_settings_get_bool(disabledSession->instance->context->settings,
                                          FreeRDP_GatewayEnabled));
        assert(freerdp_static_channel_collection_find(
                   disabledSession->instance->context->settings,
                   CLIPRDR_SVC_CHANNEL_NAME) == NULL);
        assert(freerdp_dynamic_channel_collection_find(
                   disabledSession->instance->context->settings,
                   RDPSND_CHANNEL_NAME) == NULL);
        assert(FFRSessionDestroy(&disabledSession) == FFR_RESULT_OK);
        assert(disabledSession == NULL);
    }
    assert(FFRBridgeLiveSessionCount() == 0U);

    FFRSession *session = NULL;
    assert(FFRSessionCreate(NULL, NULL, &session) == FFR_RESULT_OK);
    ThreadCheck check = { .session = &session, .result = FFR_RESULT_OK };
    pthread_t thread;
    assert(pthread_create(&thread, NULL, DestroyFromWrongThread, &check) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(check.result == FFR_RESULT_THREAD_VIOLATION);
    assert(session != NULL);
    assert(FFRSessionDestroy(&session) == FFR_RESULT_OK);
    assert(FFRBridgeLiveSessionCount() == 0U);

    puts("FarframeRDPBridge native sanitizer tests passed");
    return 0;
}

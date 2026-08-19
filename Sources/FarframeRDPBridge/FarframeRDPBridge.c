#include "FarframeRDPBridgeInternal.h"
#include <freerdp/addin.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/codec/color.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>

#include <freerdp/settings.h>
#include <winpr/error.h>
#include <winpr/user.h>
#include <winpr/wlog.h>

#include <stdlib.h>
#include <string.h>

static atomic_size_t g_liveSessionCount = 0;
static atomic_bool g_channelAddinsRegistered = false;
static const void *volatile g_staticChannelAddinAnchor = NULL;

/*
 * FreeRDP's macOS build produces static channel addins in the aggregate native
 * archive. The addin loader discovers them through generated tables at runtime,
 * so the app binary has no direct call edge to cliprdr/disp/rdpgfx/rdpsnd/rdpdr/drive
 * entry points. Without this anchor, Xcode's static archive linking can discard
 * every unreferenced channel object: settings still say "clipboard/audio/drive
 * enabled", but the final .app has no addin symbols to load.
 *
 * Keep this list aligned with scripts/build-native-dependencies.sh.
 */
extern const unsigned char CLIENT_STATIC_ENTRY_TABLES[];
extern void cliprdr_VirtualChannelEntryEx(void);
extern void disp_DVCPluginEntry(void);
extern void drdynvc_VirtualChannelEntryEx(void);
extern void drive_DeviceServiceEntry(void);
extern void mac_freerdp_rdpsnd_client_subsystem_entry(void);
extern void rdpgfx_DVCPluginEntry(void);
extern void rdpdr_VirtualChannelEntryEx(void);
extern void rdpsnd_DVCPluginEntry(void);
extern void rdpsnd_VirtualChannelEntryEx(void);

enum {
    FFR_BYTES_PER_PIXEL = 4,
    FFR_MAX_DESKTOP_DIMENSION = 16384,
    FFR_MAX_DESKTOP_BUFFER_BYTES = 256 * 1024 * 1024,
    FFR_MAX_CLIPBOARD_TEXT_BYTES = 1024 * 1024,
    FFR_MAX_CLIPBOARD_RICH_TEXT_BYTES = 8 * 1024 * 1024,
    FFR_MAX_CLIPBOARD_IMAGE_BYTES = 32 * 1024 * 1024,
    FFR_MAX_CLIPBOARD_FILE_LIST_BYTES = 128 * 1024,
    FFR_MAX_CLIPBOARD_FORMAT_NAME_BYTES = 256,
    FFR_DEFAULT_DISPLAY_SCALE_FACTOR = 100
};

static bool FFRValidateDesktopDimensions(uint32_t width, uint32_t height)
{
    if (width == 0U || height == 0U || width > FFR_MAX_DESKTOP_DIMENSION ||
        height > FFR_MAX_DESKTOP_DIMENSION) {
        return false;
    }

    const size_t packedStride = (size_t)width * FFR_BYTES_PER_PIXEL;
    return (size_t)height <= FFR_MAX_DESKTOP_BUFFER_BYTES / packedStride;
}

bool FFRValidateDesktopGeometry(uint32_t width, uint32_t height,
                                uint32_t stride, size_t *bufferLength)
{
    if (bufferLength == NULL || !FFRValidateDesktopDimensions(width, height)) {
        return false;
    }

    const size_t minimumStride = (size_t)width * FFR_BYTES_PER_PIXEL;
    if ((size_t)stride < minimumStride ||
        (size_t)height > SIZE_MAX / (size_t)stride) {
        return false;
    }

    const size_t validatedLength = (size_t)height * (size_t)stride;
    if (validatedLength > FFR_MAX_DESKTOP_BUFFER_BYTES) {
        return false;
    }
    *bufferLength = validatedLength;
    return true;
}

bool FFRValidateDirtyRectangle(int32_t x, int32_t y, int32_t width, int32_t height,
                               uint32_t desktopWidth, uint32_t desktopHeight)
{
    if (x < 0 || y < 0 || width <= 0 || height <= 0 ||
        !FFRValidateDesktopDimensions(desktopWidth, desktopHeight)) {
        return false;
    }

    const int64_t right = (int64_t)x + (int64_t)width;
    const int64_t bottom = (int64_t)y + (int64_t)height;
    return right <= (int64_t)desktopWidth && bottom <= (int64_t)desktopHeight;
}

bool FFRValidateCursorGeometry(uint32_t width, uint32_t height,
                              uint32_t hotspotX, uint32_t hotspotY,
                              size_t *bufferLength)
{
    if (bufferLength == NULL || width == 0U || height == 0U ||
        width > 512U || height > 512U || hotspotX >= width || hotspotY >= height ||
        (size_t)width > SIZE_MAX / FFR_BYTES_PER_PIXEL ||
        (size_t)height > SIZE_MAX / ((size_t)width * FFR_BYTES_PER_PIXEL)) {
        return false;
    }

    *bufferLength = (size_t)width * (size_t)height * FFR_BYTES_PER_PIXEL;
    return true;
}

static bool FFRRegisterChannelAddins(void)
{
    static const void *const requiredAddins[] = {
        CLIENT_STATIC_ENTRY_TABLES,
        (const void *)cliprdr_VirtualChannelEntryEx,
        (const void *)disp_DVCPluginEntry,
        (const void *)drdynvc_VirtualChannelEntryEx,
        (const void *)drive_DeviceServiceEntry,
        (const void *)mac_freerdp_rdpsnd_client_subsystem_entry,
        (const void *)rdpgfx_DVCPluginEntry,
        (const void *)rdpdr_VirtualChannelEntryEx,
        (const void *)rdpsnd_DVCPluginEntry,
        (const void *)rdpsnd_VirtualChannelEntryEx,
    };
    for (size_t index = 0; index < ARRAYSIZE(requiredAddins); ++index) {
        g_staticChannelAddinAnchor = requiredAddins[index];
    }

    bool expected = false;
    if (atomic_compare_exchange_strong_explicit(&g_channelAddinsRegistered, &expected, true,
                                                memory_order_acq_rel, memory_order_acquire)) {
        if (freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0) !=
            CHANNEL_RC_OK) {
            atomic_store_explicit(&g_channelAddinsRegistered, false, memory_order_release);
            return false;
        }
    }
    return true;
}

static bool FFRValidateDesktopBuffer(const rdpGdi *gdi, size_t *bufferLength)
{
    if (gdi == NULL || bufferLength == NULL || gdi->primary_buffer == NULL ||
        gdi->width <= 0 || gdi->height <= 0 ||
        !FFRValidateDesktopDimensions((uint32_t)gdi->width,
                                      (uint32_t)gdi->height)) {
        return false;
    }

    return FFRValidateDesktopGeometry((uint32_t)gdi->width, (uint32_t)gdi->height,
                                      gdi->stride, bufferLength);
}

static bool FFRValidateDirtyRect(const GDI_RGN *region, const rdpGdi *gdi)
{
    if (region == NULL || gdi == NULL || gdi->width <= 0 || gdi->height <= 0) {
        return false;
    }
    return FFRValidateDirtyRectangle(region->x, region->y, region->w, region->h,
                                     (uint32_t)gdi->width, (uint32_t)gdi->height);
}

static BOOL FFRBeginPaint(rdpContext *context)
{
    if (context == NULL || context->gdi == NULL || context->gdi->primary == NULL ||
        context->gdi->primary->hdc == NULL ||
        context->gdi->primary->hdc->hwnd == NULL ||
        context->gdi->primary->hdc->hwnd->invalid == NULL) {
        return FALSE;
    }

    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    context->gdi->primary->hdc->hwnd->ninvalid = 0;
    return TRUE;
}

static BOOL FFREndPaint(rdpContext *context)
{
    if (context == NULL || context->gdi == NULL || context->gdi->primary == NULL ||
        context->gdi->primary->hdc == NULL ||
        context->gdi->primary->hdc->hwnd == NULL ||
        context->gdi->primary->hdc->hwnd->invalid == NULL) {
        return FALSE;
    }

    rdpGdi *gdi = context->gdi;
    HGDI_WND window = gdi->primary->hdc->hwnd;
    const GDI_RGN *invalid = window->invalid;
    if (invalid->null) {
        window->ninvalid = 0;
        return TRUE;
    }

    size_t bufferLength = 0;
    if (!FFRValidateDesktopBuffer(gdi, &bufferLength) ||
        !FFRValidateDirtyRect(invalid, gdi)) {
        return FALSE;
    }

    FFRSession *session = FFRSessionFromInstance(context->instance);
    if (session == NULL) {
        return FALSE;
    }

    const FFRGraphicsEvent event = {
        .type = FFR_GRAPHICS_EVENT_FRAME,
        .desktopWidth = (uint32_t)gdi->width,
        .desktopHeight = (uint32_t)gdi->height,
        .sourceStride = gdi->stride,
        .pixels = gdi->primary_buffer,
        .bufferLength = bufferLength,
        .dirtyRect = {
            .x = invalid->x,
            .y = invalid->y,
            .width = (uint32_t)invalid->w,
            .height = (uint32_t)invalid->h,
        },
        .sequenceNumber = ++session->graphicsSequenceNumber,
    };
    FFREmitGraphicsEvent(session, &event);
    window->ninvalid = 0;
    return TRUE;
}

static BOOL FFRDesktopResize(rdpContext *context)
{
    if (context == NULL || context->settings == NULL || context->gdi == NULL) {
        return FALSE;
    }

    const uint32_t width = freerdp_settings_get_uint32(context->settings,
                                                        FreeRDP_DesktopWidth);
    const uint32_t height = freerdp_settings_get_uint32(context->settings,
                                                         FreeRDP_DesktopHeight);
    if (!FFRValidateDesktopDimensions(width, height) ||
        !gdi_resize(context->gdi, width, height)) {
        return FALSE;
    }

    FFRSession *session = FFRSessionFromInstance(context->instance);
    if (session == NULL) {
        return FALSE;
    }
    const FFRGraphicsEvent event = {
        .type = FFR_GRAPHICS_EVENT_DESKTOP_SIZE,
        .desktopWidth = width,
        .desktopHeight = height,
        .sequenceNumber = ++session->graphicsSequenceNumber,
    };
    FFREmitGraphicsEvent(session, &event);
    return TRUE;
}

bool FFRValidateResizeDimensions(uint32_t width, uint32_t height)
{
    return width >= DISPLAY_CONTROL_MIN_MONITOR_WIDTH &&
           width <= DISPLAY_CONTROL_MAX_MONITOR_WIDTH &&
           height >= DISPLAY_CONTROL_MIN_MONITOR_HEIGHT &&
           height <= DISPLAY_CONTROL_MAX_MONITOR_HEIGHT &&
           width <= UINT32_MAX / height;
}

bool FFRValidateMonitorLayout(const FFRMonitorLayout *monitors, size_t monitorCount)
{
    if (monitors == NULL || monitorCount == 0U ||
        monitorCount > FFR_MAX_MONITOR_LAYOUTS) {
        return false;
    }

    size_t primaryCount = 0U;
    for (size_t index = 0U; index < monitorCount; index += 1U) {
        const FFRMonitorLayout *monitor = &monitors[index];
        if (!FFRValidateResizeDimensions(monitor->width, monitor->height)) {
            return false;
        }
        if (monitor->left > INT32_MAX - (int32_t)monitor->width ||
            monitor->top > INT32_MAX - (int32_t)monitor->height) {
            return false;
        }
        if (monitor->desktopScaleFactor > 500U ||
            monitor->deviceScaleFactor > 500U) {
            return false;
        }
        if (monitor->primary) {
            primaryCount += 1U;
        }
    }
    return primaryCount == 1U;
}

static UINT FFRDisplayControlCaps(DispClientContext *display,
                                  UINT32 maxNumMonitors,
                                  UINT32 maxMonitorAreaFactorA,
                                  UINT32 maxMonitorAreaFactorB)
{
    (void)maxMonitorAreaFactorA;
    (void)maxMonitorAreaFactorB;
    if (display == NULL || display->custom == NULL || maxNumMonitors == 0U) {
        return ERROR_INTERNAL_ERROR;
    }
    FFRSession *session = (FFRSession *)display->custom;
    const bool wasActivated = session->displayControlActivated;
    session->displayControlActivated = true;
    if (!wasActivated) {
        FFREmitEvent(session, FFR_EVENT_DISPLAY_CONTROL_READY, FFR_RESULT_OK,
                     FFR_CONNECTION_FAILURE_NONE, 0U, NULL);
    }
    return CHANNEL_RC_OK;
}

bool FFRSendPendingResize(FFRSession *session)
{
    if (session == NULL || !session->dynamicResolutionEnabled ||
        !session->hasPendingResize || session->displayControl == NULL ||
        session->displayControl->SendMonitorLayout == NULL ||
        !session->displayControlActivated) {
        return true;
    }

    if (!FFRValidateMonitorLayout(session->pendingMonitorLayout,
                                  session->pendingMonitorCount)) {
        session->hasPendingResize = false;
        session->pendingMonitorCount = 0U;
        return true;
    }
    rdpSettings *settings = session->instance != NULL &&
                            session->instance->context != NULL
        ? session->instance->context->settings
        : NULL;
    if (settings == NULL) {
        return false;
    }

    DISPLAY_CONTROL_MONITOR_LAYOUT layouts[FFR_MAX_MONITOR_LAYOUTS] = {0};
    for (size_t index = 0U; index < session->pendingMonitorCount; index += 1U) {
        const FFRMonitorLayout *source = &session->pendingMonitorLayout[index];
        DISPLAY_CONTROL_MONITOR_LAYOUT *target = &layouts[index];
        target->Flags = source->primary ? DISPLAY_CONTROL_MONITOR_PRIMARY : 0U;
        target->Left = source->left;
        target->Top = source->top;
        target->Width = source->width;
        target->Height = source->height;
        target->PhysicalWidth = 0U;
        target->PhysicalHeight = 0U;
        target->Orientation = freerdp_settings_get_uint16(settings, FreeRDP_DesktopOrientation);
        target->DesktopScaleFactor = source->desktopScaleFactor != 0U
            ? source->desktopScaleFactor
            : freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);
        target->DeviceScaleFactor = source->deviceScaleFactor != 0U
            ? source->deviceScaleFactor
            : freerdp_settings_get_uint32(settings, FreeRDP_DeviceScaleFactor);
        if (target->DesktopScaleFactor == 0U) {
            target->DesktopScaleFactor = FFR_DEFAULT_DISPLAY_SCALE_FACTOR;
        }
        if (target->DeviceScaleFactor == 0U) {
            target->DeviceScaleFactor = FFR_DEFAULT_DISPLAY_SCALE_FACTOR;
        }
    }

    const UINT result = session->displayControl->SendMonitorLayout(
        session->displayControl, (UINT32)session->pendingMonitorCount, layouts);
    if (result != CHANNEL_RC_OK) {
        return false;
    }
    /*
     * Do not deduplicate against an earlier transport send here. During
     * desktop activation Windows can acknowledge the display-control write
     * before it applies the layout. Swift coalesces ordinary viewport changes;
     * explicit same-size requests are bounded activation retries and must
     * reach the server.
     */
    session->hasPendingResize = false;
    session->pendingMonitorCount = 0U;
    return true;
}

static UINT FFRClipboardSendCapabilities(FFRSession *session)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientCapabilities == NULL) {
        return ERROR_INVALID_PARAMETER;
    }

    CLIPRDR_GENERAL_CAPABILITY_SET generalCapabilitySet = {
        .capabilitySetType = CB_CAPSTYPE_GENERAL,
        .capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN,
        .version = CB_CAPS_VERSION_2,
        .generalFlags = CB_USE_LONG_FORMAT_NAMES |
            (session->clipboardFilesAllowed
                 ? (CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS |
                    CB_CAN_LOCK_CLIPDATA)
                 : 0U),
    };
    CLIPRDR_CAPABILITIES capabilities = {
        .cCapabilitiesSets = 1,
        .capabilitySets = (CLIPRDR_CAPABILITY_SET *)&generalCapabilitySet,
    };
    return session->clipboard->ClientCapabilities(session->clipboard, &capabilities);
}

static UINT FFRClipboardServerCapabilities(
    CliprdrClientContext *context,
    const CLIPRDR_CAPABILITIES *capabilities)
{
    if (context == NULL || context->custom == NULL || capabilities == NULL ||
        capabilities->cCapabilitiesSets == 0U || capabilities->capabilitySets == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    const CLIPRDR_GENERAL_CAPABILITY_SET *general =
        (const CLIPRDR_GENERAL_CAPABILITY_SET *)capabilities->capabilitySets;
    if (general->capabilitySetType != CB_CAPSTYPE_GENERAL ||
        general->capabilitySetLength < CB_CAPSTYPE_GENERAL_LEN) {
        return ERROR_INVALID_DATA;
    }
    FFRSession *session = (FFRSession *)context->custom;
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return ERROR_INTERNAL_ERROR;
    }
    session->remoteClipboardLockSupported = session->clipboardFilesAllowed &&
        (general->generalFlags & CB_CAN_LOCK_CLIPDATA) != 0U;
    pthread_mutex_unlock(&session->clipboardMutex);
    return CHANNEL_RC_OK;
}

static UINT FFRClipboardSendFormatListResponse(FFRSession *session, bool success)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientFormatListResponse == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    const CLIPRDR_FORMAT_LIST_RESPONSE response = {
        .common = {
            .msgType = CB_FORMAT_LIST_RESPONSE,
            .msgFlags = success ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
        },
    };
    return session->clipboard->ClientFormatListResponse(session->clipboard, &response);
}

static size_t FFRClipboardMaximumPayloadSize(FFRClipboardFormatKind format)
{
    switch (format) {
    case FFR_CLIPBOARD_FORMAT_UNICODE_TEXT:
        return FFR_MAX_CLIPBOARD_TEXT_BYTES;
    case FFR_CLIPBOARD_FORMAT_HTML:
    case FFR_CLIPBOARD_FORMAT_RTF:
        return FFR_MAX_CLIPBOARD_RICH_TEXT_BYTES;
    case FFR_CLIPBOARD_FORMAT_DIB:
    case FFR_CLIPBOARD_FORMAT_DIBV5:
    case FFR_CLIPBOARD_FORMAT_PNG:
        return FFR_MAX_CLIPBOARD_IMAGE_BYTES;
    case FFR_CLIPBOARD_FORMAT_FILE_LIST:
        return FFR_MAX_CLIPBOARD_FILE_LIST_BYTES;
    default:
        return 0U;
    }
}

bool FFRClipboardFormatAllowed(const FFRSession *session,
                               FFRClipboardFormatKind format,
                               bool localToRemote)
{
    if (session == NULL || !session->clipboardEnabled ||
        (localToRemote && !session->clipboardLocalToRemote) ||
        (!localToRemote && !session->clipboardRemoteToLocal)) {
        return false;
    }
    switch (format) {
    case FFR_CLIPBOARD_FORMAT_UNICODE_TEXT:
        return session->clipboardTextAllowed;
    case FFR_CLIPBOARD_FORMAT_HTML:
    case FFR_CLIPBOARD_FORMAT_RTF:
        return session->clipboardFormattedTextAllowed;
    case FFR_CLIPBOARD_FORMAT_DIB:
    case FFR_CLIPBOARD_FORMAT_DIBV5:
    case FFR_CLIPBOARD_FORMAT_PNG:
        return session->clipboardImagesAllowed;
    case FFR_CLIPBOARD_FORMAT_FILE_LIST:
        return session->clipboardFilesAllowed;
    default:
        return false;
    }
}

static bool FFRClipboardLocalFormat(FFRClipboardFormatKind kind,
                                    uint32_t *formatId,
                                    const char **formatName)
{
    if (formatId == NULL || formatName == NULL) {
        return false;
    }
    *formatName = NULL;
    switch (kind) {
    case FFR_CLIPBOARD_FORMAT_UNICODE_TEXT:
        *formatId = CF_UNICODETEXT;
        return true;
    case FFR_CLIPBOARD_FORMAT_HTML:
        *formatId = 0xC100U;
        *formatName = "HTML Format";
        return true;
    case FFR_CLIPBOARD_FORMAT_RTF:
        *formatId = 0xC101U;
        *formatName = "Rich Text Format";
        return true;
    case FFR_CLIPBOARD_FORMAT_DIB:
        *formatId = CF_DIB;
        return true;
    case FFR_CLIPBOARD_FORMAT_DIBV5:
        *formatId = CF_DIBV5;
        return true;
    case FFR_CLIPBOARD_FORMAT_PNG:
        *formatId = 0xC103U;
        *formatName = "PNG";
        return true;
    case FFR_CLIPBOARD_FORMAT_FILE_LIST:
        *formatId = 0xC102U;
        *formatName = "FileGroupDescriptorW";
        return true;
    default:
        return false;
    }
}

bool FFRClipboardRemoteFormat(const CLIPRDR_FORMAT *format,
                              FFRClipboardFormatKind *kind)
{
    if (format == NULL || kind == NULL) {
        return false;
    }
    if (format->formatName != NULL) {
        const size_t length = strnlen(format->formatName,
                                      FFR_MAX_CLIPBOARD_FORMAT_NAME_BYTES + 1U);
        if (length == 0U || length > FFR_MAX_CLIPBOARD_FORMAT_NAME_BYTES) {
            return false;
        }
        if (strcmp(format->formatName, "HTML Format") == 0) {
            *kind = FFR_CLIPBOARD_FORMAT_HTML;
            return true;
        }
        if (strcmp(format->formatName, "Rich Text Format") == 0) {
            *kind = FFR_CLIPBOARD_FORMAT_RTF;
            return true;
        }
        if (strcmp(format->formatName, "FileGroupDescriptorW") == 0) {
            *kind = FFR_CLIPBOARD_FORMAT_FILE_LIST;
            return true;
        }
        if (strcmp(format->formatName, "PNG") == 0) {
            *kind = FFR_CLIPBOARD_FORMAT_PNG;
            return true;
        }
        return false;
    }
    switch (format->formatId) {
    case CF_UNICODETEXT:
        *kind = FFR_CLIPBOARD_FORMAT_UNICODE_TEXT;
        return true;
    case CF_DIB:
        *kind = FFR_CLIPBOARD_FORMAT_DIB;
        return true;
    case CF_DIBV5:
        *kind = FFR_CLIPBOARD_FORMAT_DIBV5;
        return true;
    default:
        return false;
    }
}

bool FFRSendClipboardDataRequest(FFRSession *session,
                                 uint64_t generation,
                                 uint32_t remoteFormatId,
                                 FFRClipboardFormatKind format)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientFormatDataRequest == NULL ||
        FFRClipboardMaximumPayloadSize(format) == 0U ||
        !FFRClipboardFormatAllowed(session, format, false)) {
        return false;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return false;
    }
    if (generation == 0U || generation != session->remoteClipboardGeneration ||
        session->clipboardRequestPending) {
        pthread_mutex_unlock(&session->clipboardMutex);
        return false;
    }
    session->clipboardRequestPending = true;
    session->pendingClipboardGeneration = generation;
    session->pendingClipboardFormatId = remoteFormatId;
    session->pendingClipboardFormat = format;
    pthread_mutex_unlock(&session->clipboardMutex);

    CLIPRDR_FORMAT_DATA_REQUEST request = {
        .common = {
            .msgType = CB_FORMAT_DATA_REQUEST,
        },
        .requestedFormatId = remoteFormatId,
    };
    session->clipboard->lastRequestedFormatId = remoteFormatId;
    if (session->clipboard->ClientFormatDataRequest(session->clipboard, &request) ==
        CHANNEL_RC_OK) {
        return true;
    }

    if (pthread_mutex_lock(&session->clipboardMutex) == 0) {
        session->clipboardRequestPending = false;
        pthread_mutex_unlock(&session->clipboardMutex);
    }
    return false;
}

static UINT FFRClipboardSendFormatDataFail(FFRSession *session)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientFormatDataResponse == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    const CLIPRDR_FORMAT_DATA_RESPONSE response = {
        .common = {
            .msgType = CB_FORMAT_DATA_RESPONSE,
            .msgFlags = CB_RESPONSE_FAIL,
        },
    };
    return session->clipboard->ClientFormatDataResponse(session->clipboard, &response);
}

static UINT FFRClipboardSendLocalDataResponse(FFRSession *session, uint32_t formatId)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientFormatDataResponse == NULL) {
        return ERROR_INVALID_PARAMETER;
    }

    uint8_t *snapshot = NULL;
    size_t snapshotLength = 0U;
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return ERROR_INTERNAL_ERROR;
    }
    for (size_t index = 0U; index < session->localClipboardPayloadCount; index += 1U) {
        const FFRStoredClipboardPayload *payload = &session->localClipboardPayloads[index];
        if (payload->formatId == formatId &&
            FFRClipboardFormatAllowed(session, payload->kind, true) &&
            payload->bytes != NULL && payload->length > 0U) {
            snapshot = malloc(payload->length);
            if (snapshot != NULL) {
                memcpy(snapshot, payload->bytes, payload->length);
                snapshotLength = payload->length;
            }
            break;
        }
    }
    pthread_mutex_unlock(&session->clipboardMutex);

    if (snapshot == NULL || snapshotLength > UINT32_MAX) {
        free(snapshot);
        return FFRClipboardSendFormatDataFail(session);
    }

    const CLIPRDR_FORMAT_DATA_RESPONSE response = {
        .common = {
            .msgType = CB_FORMAT_DATA_RESPONSE,
            .msgFlags = CB_RESPONSE_OK,
            .dataLen = (UINT32)snapshotLength,
        },
        .requestedFormatData = snapshot,
    };
    const UINT result = session->clipboard->ClientFormatDataResponse(session->clipboard,
                                                                     &response);
    free(snapshot);
    return result;
}

bool FFRSendClipboardFormatList(FFRSession *session)
{
    if (session == NULL || !session->clipboardEnabled ||
        !session->clipboardLocalToRemote || !session->clipboardReady ||
        session->clipboard == NULL || session->clipboard->ClientFormatList == NULL) {
        return true;
    }

    CLIPRDR_FORMAT formats[FFR_MAX_CLIPBOARD_FORMATS] = { 0 };
    UINT32 numFormats = 0U;

    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return false;
    }
    for (size_t index = 0U; index < session->localClipboardPayloadCount; index += 1U) {
        uint32_t formatId = 0U;
        const char *formatName = NULL;
        if (FFRClipboardFormatAllowed(session,
                                      session->localClipboardPayloads[index].kind,
                                      true) &&
            FFRClipboardLocalFormat(session->localClipboardPayloads[index].kind,
                                    &formatId, &formatName)) {
            formats[numFormats].formatId = formatId;
            formats[numFormats].formatName = (char *)formatName;
            numFormats += 1U;
        }
    }
    pthread_mutex_unlock(&session->clipboardMutex);
    const CLIPRDR_FORMAT_LIST formatList = {
        .common = {
            .msgType = CB_FORMAT_LIST,
        },
        .numFormats = numFormats,
        .formats = formats,
    };
    const UINT result = session->clipboard->ClientFormatList(session->clipboard, &formatList);
    return result == CHANNEL_RC_OK;
}

size_t FFRClipboardUTF16Length(const BYTE *data, UINT32 byteLength)
{
    if (data == NULL || byteLength == 0U || (byteLength % sizeof(uint16_t)) != 0U) {
        return SIZE_MAX;
    }
    const size_t codeUnits = byteLength / sizeof(uint16_t);
    const uint16_t *utf16 = (const uint16_t *)data;
    for (size_t index = 0U; index < codeUnits; index += 1U) {
        if (utf16[index] == 0U) {
            return index;
        }
    }
    return SIZE_MAX;
}

static UINT FFRClipboardMonitorReady(CliprdrClientContext *context,
                                     const CLIPRDR_MONITOR_READY *monitorReady)
{
    (void)monitorReady;
    if (context == NULL || context->custom == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    FFRSession *session = (FFRSession *)context->custom;
    const UINT capsResult = FFRClipboardSendCapabilities(session);
    if (capsResult != CHANNEL_RC_OK) {
        return capsResult;
    }

    session->clipboardReady = true;
    const FFRClipboardEvent event = { .type = FFR_CLIPBOARD_EVENT_READY };
    FFREmitClipboardEvent(session, &event);
    return FFRSendClipboardFormatList(session) ? CHANNEL_RC_OK : ERROR_INTERNAL_ERROR;
}

static UINT FFRClipboardServerFormatList(CliprdrClientContext *context,
                                         const CLIPRDR_FORMAT_LIST *formatList)
{
    if (context == NULL || context->custom == NULL || formatList == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    FFRSession *session = (FFRSession *)context->custom;
    const bool validCount = formatList->numFormats <= FFR_MAX_REMOTE_CLIPBOARD_FORMATS;
    const UINT response = FFRClipboardSendFormatListResponse(
        session, session->clipboardEnabled && session->clipboardRemoteToLocal && validCount);
    if (response != CHANNEL_RC_OK || !session->clipboardEnabled ||
        !session->clipboardRemoteToLocal || !validCount) {
        return response;
    }

    FFRClipboardFormatDescriptor formats[FFR_MAX_CLIPBOARD_FORMATS] = { 0 };
    size_t formatCount = 0U;
    for (UINT32 index = 0U; index < formatList->numFormats; index += 1U) {
        FFRClipboardFormatKind kind = 0;
        if (!FFRClipboardRemoteFormat(&formatList->formats[index], &kind) ||
            !FFRClipboardFormatAllowed(session, kind, false)) {
            continue;
        }
        bool duplicate = false;
        for (size_t existing = 0U; existing < formatCount; existing += 1U) {
            if (formats[existing].kind == kind) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate && formatCount < FFR_MAX_CLIPBOARD_FORMATS) {
            formats[formatCount].kind = kind;
            formats[formatCount].formatId = formatList->formats[index].formatId;
            formatCount += 1U;
        }
    }

    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return ERROR_INTERNAL_ERROR;
    }
    session->remoteClipboardGeneration += 1U;
    if (session->remoteClipboardGeneration == 0U) {
        session->remoteClipboardGeneration = 1U;
    }
    session->clipboardRequestPending = false;
    if (!session->remoteClipboardLocked) {
        session->remoteFileRequestPending = false;
    }
    const uint64_t generation = session->remoteClipboardGeneration;
    pthread_mutex_unlock(&session->clipboardMutex);

    const FFRClipboardEvent event = {
        .type = FFR_CLIPBOARD_EVENT_REMOTE_OFFER,
        .generation = generation,
        .formats = formats,
        .formatCount = formatCount,
    };
    FFREmitClipboardEvent(session, &event);
    return CHANNEL_RC_OK;
}

static UINT FFRClipboardServerFormatListResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_LIST_RESPONSE *formatListResponse)
{
    (void)context;
    (void)formatListResponse;
    return CHANNEL_RC_OK;
}

static UINT FFRClipboardServerFormatDataRequest(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_DATA_REQUEST *formatDataRequest)
{
    if (context == NULL || context->custom == NULL || formatDataRequest == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    FFRSession *session = (FFRSession *)context->custom;
    if (!session->clipboardEnabled || !session->clipboardLocalToRemote) {
        return FFRClipboardSendFormatDataFail(session);
    }
    return FFRClipboardSendLocalDataResponse(session, formatDataRequest->requestedFormatId);
}

static UINT FFRClipboardServerFormatDataResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_DATA_RESPONSE *formatDataResponse)
{
    if (context == NULL || context->custom == NULL || formatDataResponse == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    FFRSession *session = (FFRSession *)context->custom;
    if (!session->clipboardEnabled || !session->clipboardRemoteToLocal ||
        session->clipboard == NULL) {
        return CHANNEL_RC_OK;
    }

    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return ERROR_INTERNAL_ERROR;
    }
    if (!session->clipboardRequestPending) {
        pthread_mutex_unlock(&session->clipboardMutex);
        return CHANNEL_RC_OK;
    }
    const uint64_t generation = session->pendingClipboardGeneration;
    const FFRClipboardFormatKind format = session->pendingClipboardFormat;
    const uint32_t formatId = session->pendingClipboardFormatId;
    session->clipboardRequestPending = false;
    const bool current = generation == session->remoteClipboardGeneration;
    pthread_mutex_unlock(&session->clipboardMutex);

    const bool success = current && session->clipboard->lastRequestedFormatId == formatId &&
        (formatDataResponse->common.msgFlags & CB_RESPONSE_FAIL) == 0U &&
        formatDataResponse->common.dataLen > 0U &&
        formatDataResponse->common.dataLen <= FFRClipboardMaximumPayloadSize(format);
    const FFRClipboardEvent dataEvent = {
        .type = FFR_CLIPBOARD_EVENT_REMOTE_DATA,
        .length = success ? formatDataResponse->common.dataLen : 0U,
        .generation = generation,
        .format = format,
        .bytes = success ? formatDataResponse->requestedFormatData : NULL,
    };
    FFREmitClipboardEvent(session, &dataEvent);

    if (!success || format != FFR_CLIPBOARD_FORMAT_UNICODE_TEXT) {
        return CHANNEL_RC_OK;
    }
    const size_t length = FFRClipboardUTF16Length(formatDataResponse->requestedFormatData,
                                                  formatDataResponse->common.dataLen);
    if (length == SIZE_MAX) {
        return CHANNEL_RC_OK;
    }
    const FFRClipboardEvent event = {
        .type = FFR_CLIPBOARD_EVENT_REMOTE_TEXT,
        .utf16CodeUnits = (const uint16_t *)formatDataResponse->requestedFormatData,
        .length = length,
    };
    FFREmitClipboardEvent(session, &event);
    return CHANNEL_RC_OK;
}

static UINT FFRClipboardSendImmediateFileFailure(FFRSession *session, uint32_t streamId)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientFileContentsResponse == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    const CLIPRDR_FILE_CONTENTS_RESPONSE response = {
        .common = { .msgType = CB_FILECONTENTS_RESPONSE, .msgFlags = CB_RESPONSE_FAIL },
        .streamId = streamId,
    };
    return session->clipboard->ClientFileContentsResponse(session->clipboard, &response);
}

bool FFRSendClipboardFileResponse(FFRSession *session, uint64_t requestId)
{
    if (session == NULL || requestId == 0U || session->clipboard == NULL ||
        session->clipboard->ClientFileContentsResponse == NULL) {
        return false;
    }
    FFRClipboardLocalFileRequest snapshot = { 0 };
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return false;
    }
    for (size_t index = 0U; index < FFR_MAX_CLIPBOARD_FILE_REQUESTS; index += 1U) {
        FFRClipboardLocalFileRequest *request = &session->localFileRequests[index];
        if (request->active && request->requestId == requestId && request->responseReady) {
            snapshot = *request;
            memset(request, 0, sizeof(*request));
            break;
        }
    }
    const bool current = snapshot.requestId != 0U &&
        snapshot.generation == session->localClipboardGeneration &&
        session->clipboardLocalToRemote && session->clipboardFilesAllowed;
    pthread_mutex_unlock(&session->clipboardMutex);
    if (snapshot.requestId == 0U) {
        return false;
    }
    const bool success = current && snapshot.success;
    const CLIPRDR_FILE_CONTENTS_RESPONSE response = {
        .common = {
            .msgType = CB_FILECONTENTS_RESPONSE,
            .msgFlags = success ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
        },
        .streamId = snapshot.streamId,
        .cbRequested = success ? (UINT32)snapshot.responseLength : 0U,
        .requestedData = success ? snapshot.responseBytes : NULL,
    };
    const UINT result = session->clipboard->ClientFileContentsResponse(
        session->clipboard, &response);
    free(snapshot.responseBytes);
    return result == CHANNEL_RC_OK;
}

bool FFRSendClipboardFileRequest(FFRSession *session,
                                 uint64_t generation,
                                 uint32_t streamId,
                                 uint32_t listIndex,
                                 FFRClipboardFileRequestKind kind,
                                 uint64_t offset,
                                 uint32_t requestedBytes)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientFileContentsRequest == NULL || streamId == 0U ||
        !FFRClipboardFormatAllowed(session, FFR_CLIPBOARD_FORMAT_FILE_LIST, false) ||
        (kind != FFR_CLIPBOARD_FILE_REQUEST_SIZE &&
         kind != FFR_CLIPBOARD_FILE_REQUEST_RANGE) ||
        (kind == FFR_CLIPBOARD_FILE_REQUEST_RANGE &&
         (requestedBytes == 0U || requestedBytes > FFR_MAX_CLIPBOARD_FILE_RANGE_BYTES ||
          UINT64_MAX - offset < requestedBytes))) {
        return false;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return false;
    }
    const bool currentGeneration = generation == session->remoteClipboardGeneration ||
        (session->remoteClipboardLocked &&
         generation == session->lockedRemoteClipboardGeneration);
    if (generation == 0U || !currentGeneration ||
        session->remoteFileRequestPending) {
        pthread_mutex_unlock(&session->clipboardMutex);
        return false;
    }
    const bool haveClipDataId = session->remoteClipboardLocked &&
        session->lockedRemoteClipboardGeneration == generation;
    const uint32_t clipDataId = haveClipDataId
        ? session->remoteClipboardClipDataId : 0U;
    session->remoteFileRequestPending = true;
    session->pendingRemoteFileGeneration = generation;
    session->pendingRemoteFileStreamId = streamId;
    session->pendingRemoteFileListIndex = listIndex;
    session->pendingRemoteFileKind = kind;
    session->pendingRemoteFileOffset = offset;
    session->pendingRemoteFileRequestedBytes = kind == FFR_CLIPBOARD_FILE_REQUEST_SIZE
        ? (uint32_t)sizeof(uint64_t) : requestedBytes;
    pthread_mutex_unlock(&session->clipboardMutex);

    const CLIPRDR_FILE_CONTENTS_REQUEST request = {
        .common = { .msgType = CB_FILECONTENTS_REQUEST },
        .streamId = streamId,
        .listIndex = listIndex,
        .dwFlags = kind == FFR_CLIPBOARD_FILE_REQUEST_SIZE
            ? FILECONTENTS_SIZE : FILECONTENTS_RANGE,
        .nPositionLow = (uint32_t)offset,
        .nPositionHigh = (uint32_t)(offset >> 32U),
        .cbRequested = kind == FFR_CLIPBOARD_FILE_REQUEST_SIZE
            ? (uint32_t)sizeof(uint64_t) : requestedBytes,
        .haveClipDataId = haveClipDataId ? TRUE : FALSE,
        .clipDataId = clipDataId,
    };
    if (session->clipboard->ClientFileContentsRequest(session->clipboard, &request) ==
        CHANNEL_RC_OK) {
        return true;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) == 0) {
        session->remoteFileRequestPending = false;
        pthread_mutex_unlock(&session->clipboardMutex);
    }
    return false;
}

bool FFRSendClipboardLock(FFRSession *session, uint64_t generation)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientLockClipboardData == NULL) {
        return false;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return false;
    }
    if (!session->remoteClipboardLockSupported || generation == 0U ||
        generation != session->remoteClipboardGeneration ||
        session->remoteClipboardLocked) {
        pthread_mutex_unlock(&session->clipboardMutex);
        return false;
    }
    uint32_t clipDataId = (uint32_t)generation ^ (uint32_t)(generation >> 32U);
    if (clipDataId == 0U) {
        clipDataId = 1U;
    }
    pthread_mutex_unlock(&session->clipboardMutex);
    const CLIPRDR_LOCK_CLIPBOARD_DATA request = {
        .common = { .msgType = CB_LOCK_CLIPDATA },
        .clipDataId = clipDataId,
    };
    if (session->clipboard->ClientLockClipboardData(session->clipboard, &request) !=
        CHANNEL_RC_OK) {
        return false;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return false;
    }
    session->remoteClipboardLocked = true;
    session->lockedRemoteClipboardGeneration = generation;
    session->remoteClipboardClipDataId = clipDataId;
    pthread_mutex_unlock(&session->clipboardMutex);
    return true;
}

bool FFRSendClipboardUnlock(FFRSession *session, uint64_t generation)
{
    if (session == NULL || session->clipboard == NULL ||
        session->clipboard->ClientUnlockClipboardData == NULL) {
        return false;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return false;
    }
    if (!session->remoteClipboardLocked ||
        session->lockedRemoteClipboardGeneration != generation) {
        pthread_mutex_unlock(&session->clipboardMutex);
        return true;
    }
    const uint32_t clipDataId = session->remoteClipboardClipDataId;
    pthread_mutex_unlock(&session->clipboardMutex);
    const CLIPRDR_UNLOCK_CLIPBOARD_DATA request = {
        .common = { .msgType = CB_UNLOCK_CLIPDATA },
        .clipDataId = clipDataId,
    };
    if (session->clipboard->ClientUnlockClipboardData(session->clipboard, &request) !=
        CHANNEL_RC_OK) {
        return false;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) == 0) {
        if (session->lockedRemoteClipboardGeneration == generation) {
            session->remoteClipboardLocked = false;
            session->lockedRemoteClipboardGeneration = 0U;
            session->remoteClipboardClipDataId = 0U;
        }
        pthread_mutex_unlock(&session->clipboardMutex);
    }
    return true;
}

static UINT FFRClipboardServerFileContentsRequest(
    CliprdrClientContext *context,
    const CLIPRDR_FILE_CONTENTS_REQUEST *fileContentsRequest)
{
    if (context == NULL || context->custom == NULL || fileContentsRequest == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    FFRSession *session = (FFRSession *)context->custom;
    const FFRClipboardFileRequestKind kind =
        fileContentsRequest->dwFlags == FILECONTENTS_SIZE
            ? FFR_CLIPBOARD_FILE_REQUEST_SIZE
            : FFR_CLIPBOARD_FILE_REQUEST_RANGE;
    const uint64_t offset = ((uint64_t)fileContentsRequest->nPositionHigh << 32U) |
        fileContentsRequest->nPositionLow;
    if (!FFRClipboardFormatAllowed(session, FFR_CLIPBOARD_FORMAT_FILE_LIST, true) ||
        (fileContentsRequest->dwFlags != FILECONTENTS_SIZE &&
         fileContentsRequest->dwFlags != FILECONTENTS_RANGE) ||
        (kind == FFR_CLIPBOARD_FILE_REQUEST_RANGE &&
         (fileContentsRequest->cbRequested == 0U ||
          fileContentsRequest->cbRequested > FFR_MAX_CLIPBOARD_FILE_RANGE_BYTES ||
          UINT64_MAX - offset < fileContentsRequest->cbRequested))) {
        return FFRClipboardSendImmediateFileFailure(session, fileContentsRequest->streamId);
    }

    FFRClipboardLocalFileRequest *request = NULL;
    uint32_t fileCount = 0U;
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return ERROR_INTERNAL_ERROR;
    }
    for (size_t index = 0U; index < session->localClipboardPayloadCount; index += 1U) {
        const FFRStoredClipboardPayload *payload = &session->localClipboardPayloads[index];
        if (payload->kind == FFR_CLIPBOARD_FORMAT_FILE_LIST && payload->length >= 4U) {
            fileCount = (uint32_t)payload->bytes[0] |
                ((uint32_t)payload->bytes[1] << 8U) |
                ((uint32_t)payload->bytes[2] << 16U) |
                ((uint32_t)payload->bytes[3] << 24U);
            break;
        }
    }
    if (fileContentsRequest->listIndex < fileCount) {
        for (size_t index = 0U; index < FFR_MAX_CLIPBOARD_FILE_REQUESTS; index += 1U) {
            if (!session->localFileRequests[index].active) {
                request = &session->localFileRequests[index];
                break;
            }
        }
    }
    if (request == NULL) {
        pthread_mutex_unlock(&session->clipboardMutex);
        return FFRClipboardSendImmediateFileFailure(session, fileContentsRequest->streamId);
    }
    session->nextFileRequestId += 1U;
    if (session->nextFileRequestId == 0U) {
        session->nextFileRequestId = 1U;
    }
    *request = (FFRClipboardLocalFileRequest) {
        .active = true,
        .requestId = session->nextFileRequestId,
        .generation = session->localClipboardGeneration,
        .streamId = fileContentsRequest->streamId,
        .listIndex = fileContentsRequest->listIndex,
        .kind = kind,
        .offset = offset,
        .requestedBytes = kind == FFR_CLIPBOARD_FILE_REQUEST_SIZE
            ? (uint32_t)sizeof(uint64_t) : fileContentsRequest->cbRequested,
    };
    const uint64_t requestId = request->requestId;
    const uint64_t generation = request->generation;
    pthread_mutex_unlock(&session->clipboardMutex);
    const FFRClipboardEvent event = {
        .type = FFR_CLIPBOARD_EVENT_LOCAL_FILE_REQUEST,
        .generation = generation,
        .fileRequestId = requestId,
        .streamId = fileContentsRequest->streamId,
        .listIndex = fileContentsRequest->listIndex,
        .fileRequestKind = kind,
        .fileOffset = offset,
        .requestedBytes = kind == FFR_CLIPBOARD_FILE_REQUEST_SIZE
            ? (uint32_t)sizeof(uint64_t) : fileContentsRequest->cbRequested,
    };
    FFREmitClipboardEvent(session, &event);
    return CHANNEL_RC_OK;
}

static UINT FFRClipboardServerFileContentsResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FILE_CONTENTS_RESPONSE *fileContentsResponse)
{
    if (context == NULL || context->custom == NULL || fileContentsResponse == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    FFRSession *session = (FFRSession *)context->custom;
    if (pthread_mutex_lock(&session->clipboardMutex) != 0) {
        return ERROR_INTERNAL_ERROR;
    }
    if (!session->remoteFileRequestPending ||
        session->pendingRemoteFileStreamId != fileContentsResponse->streamId) {
        pthread_mutex_unlock(&session->clipboardMutex);
        return CHANNEL_RC_OK;
    }
    const uint64_t generation = session->pendingRemoteFileGeneration;
    const FFRClipboardFileRequestKind kind = session->pendingRemoteFileKind;
    const uint32_t requestedBytes = session->pendingRemoteFileRequestedBytes;
    session->remoteFileRequestPending = false;
    const bool current = generation == session->remoteClipboardGeneration ||
        (session->remoteClipboardLocked &&
         generation == session->lockedRemoteClipboardGeneration);
    pthread_mutex_unlock(&session->clipboardMutex);
    const bool success = current &&
        (fileContentsResponse->common.msgFlags & CB_RESPONSE_FAIL) == 0U &&
        fileContentsResponse->cbRequested <= requestedBytes &&
        (kind != FFR_CLIPBOARD_FILE_REQUEST_SIZE ||
         fileContentsResponse->cbRequested == sizeof(uint64_t)) &&
        (fileContentsResponse->cbRequested == 0U ||
         fileContentsResponse->requestedData != NULL);
    const FFRClipboardEvent event = {
        .type = FFR_CLIPBOARD_EVENT_REMOTE_FILE_DATA,
        .length = success ? fileContentsResponse->cbRequested : 0U,
        .generation = generation,
        .bytes = success ? fileContentsResponse->requestedData : NULL,
        .streamId = fileContentsResponse->streamId,
        .fileRequestKind = kind,
        .requestedBytes = requestedBytes,
        .success = success,
    };
    FFREmitClipboardEvent(session, &event);
    return CHANNEL_RC_OK;
}

void FFRClearClipboardState(FFRSession *session)
{
    if (session == NULL) {
        return;
    }
    if (pthread_mutex_lock(&session->clipboardMutex) == 0) {
        for (size_t index = 0U; index < session->localClipboardPayloadCount; index += 1U) {
            free(session->localClipboardPayloads[index].bytes);
            memset(&session->localClipboardPayloads[index], 0,
                   sizeof(session->localClipboardPayloads[index]));
        }
        session->localClipboardPayloadCount = 0U;
        session->localClipboardGeneration = 0U;
        session->remoteClipboardGeneration = 0U;
        session->clipboardRequestPending = false;
        session->remoteFileRequestPending = false;
        session->remoteClipboardLockSupported = false;
        session->remoteClipboardLocked = false;
        session->lockedRemoteClipboardGeneration = 0U;
        session->remoteClipboardClipDataId = 0U;
        for (size_t index = 0U; index < FFR_MAX_CLIPBOARD_FILE_REQUESTS; index += 1U) {
            free(session->localFileRequests[index].responseBytes);
            memset(&session->localFileRequests[index], 0,
                   sizeof(session->localFileRequests[index]));
        }
        pthread_mutex_unlock(&session->clipboardMutex);
    }
    session->clipboard = NULL;
    session->clipboardReady = false;
}

static void FFROnChannelConnected(void *context, const ChannelConnectedEventArgs *event)
{
    if (context == NULL || event == NULL || event->name == NULL) {
        return;
    }
    FFRRdpContext *farframeContext = (FFRRdpContext *)context;
    FFRSession *session = farframeContext->session;
    if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        RdpgfxClientContext *graphicsPipeline =
            (RdpgfxClientContext *)event->pInterface;
        if (session != NULL && graphicsPipeline != NULL &&
            farframeContext->base.gdi != NULL &&
            gdi_graphics_pipeline_init(farframeContext->base.gdi,
                                       graphicsPipeline)) {
            session->graphicsPipeline = graphicsPipeline;
            session->graphicsPipelineActive = true;
        }
        return;
    }
    if (session != NULL && strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        session->displayControl = (DispClientContext *)event->pInterface;
        if (session->displayControl != NULL) {
            session->displayControl->custom = session;
            session->displayControl->DisplayControlCaps = FFRDisplayControlCaps;
        }
        return;
    }
    if (session != NULL && strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        session->clipboard = (CliprdrClientContext *)event->pInterface;
        if (session->clipboard != NULL) {
            session->clipboard->custom = session;
            session->clipboard->ServerCapabilities = FFRClipboardServerCapabilities;
            session->clipboard->MonitorReady = FFRClipboardMonitorReady;
            session->clipboard->ServerFormatList = FFRClipboardServerFormatList;
            session->clipboard->ServerFormatListResponse = FFRClipboardServerFormatListResponse;
            session->clipboard->ServerFormatDataRequest = FFRClipboardServerFormatDataRequest;
            session->clipboard->ServerFormatDataResponse = FFRClipboardServerFormatDataResponse;
            session->clipboard->ServerFileContentsRequest =
                FFRClipboardServerFileContentsRequest;
            session->clipboard->ServerFileContentsResponse =
                FFRClipboardServerFileContentsResponse;
        }
        return;
    }
    freerdp_client_OnChannelConnectedEventHandler(context, event);
}

static void FFROnChannelDisconnected(void *context, const ChannelDisconnectedEventArgs *event)
{
    if (context == NULL || event == NULL || event->name == NULL) {
        return;
    }
    FFRRdpContext *farframeContext = (FFRRdpContext *)context;
    FFRSession *session = farframeContext->session;
    if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        RdpgfxClientContext *graphicsPipeline =
            (RdpgfxClientContext *)event->pInterface;
        if (session != NULL && graphicsPipeline == session->graphicsPipeline) {
            if (session->graphicsPipelineActive &&
                farframeContext->base.gdi != NULL) {
                gdi_graphics_pipeline_uninit(farframeContext->base.gdi,
                                             graphicsPipeline);
            }
            session->graphicsPipeline = NULL;
            session->graphicsPipelineActive = false;
        }
        return;
    }
    if (session != NULL && strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        if (session->displayControl != NULL) {
            session->displayControl->custom = NULL;
            session->displayControl->DisplayControlCaps = NULL;
        }
        session->displayControl = NULL;
        session->displayControlActivated = false;
        return;
    }
    if (session != NULL && strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        if (session->clipboard != NULL) {
            session->clipboard->custom = NULL;
            session->clipboard->ServerCapabilities = NULL;
            session->clipboard->MonitorReady = NULL;
            session->clipboard->ServerFormatList = NULL;
            session->clipboard->ServerFormatListResponse = NULL;
            session->clipboard->ServerFormatDataRequest = NULL;
            session->clipboard->ServerFormatDataResponse = NULL;
            session->clipboard->ServerFileContentsRequest = NULL;
            session->clipboard->ServerFileContentsResponse = NULL;
        }
        FFRClearClipboardState(session);
        return;
    }
    freerdp_client_OnChannelDisconnectedEventHandler(context, event);
}

typedef struct FFRPointer {
    rdpPointer base;
    uint8_t *pixels;
    size_t bufferLength;
} FFRPointer;

static FFRSession *FFRSessionFromContext(rdpContext *context)
{
    if (context == NULL) {
        return NULL;
    }
    return FFRSessionFromInstance(context->instance);
}

static BOOL FFRPointerNew(rdpContext *context, rdpPointer *pointer)
{
    size_t bufferLength = 0U;
    if (context == NULL || pointer == NULL ||
        !FFRValidateCursorGeometry(pointer->width, pointer->height,
                                   pointer->xPos, pointer->yPos, &bufferLength) ||
        (pointer->lengthXorMask > 0U && pointer->xorMaskData == NULL) ||
        (pointer->lengthAndMask > 0U && pointer->andMaskData == NULL)) {
        return FALSE;
    }

    FFRPointer *farframePointer = (FFRPointer *)pointer;
    farframePointer->bufferLength = bufferLength;
    farframePointer->pixels = calloc(1, farframePointer->bufferLength);
    if (farframePointer->pixels == NULL) {
        return FALSE;
    }

    if (!freerdp_image_copy_from_pointer_data(
            farframePointer->pixels, PIXEL_FORMAT_BGRA32, 0U, 0U, 0U,
            pointer->width, pointer->height, pointer->xorMaskData,
            pointer->lengthXorMask, pointer->andMaskData,
            pointer->lengthAndMask, pointer->xorBpp, NULL)) {
        free(farframePointer->pixels);
        farframePointer->pixels = NULL;
        farframePointer->bufferLength = 0U;
        return FALSE;
    }
    return TRUE;
}

static void FFRPointerFree(rdpContext *context, rdpPointer *pointer)
{
    (void)context;
    if (pointer == NULL) {
        return;
    }
    FFRPointer *farframePointer = (FFRPointer *)pointer;
    free(farframePointer->pixels);
    farframePointer->pixels = NULL;
    farframePointer->bufferLength = 0U;
}

static BOOL FFRPointerSet(rdpContext *context, rdpPointer *pointer)
{
    FFRSession *session = FFRSessionFromContext(context);
    if (session == NULL || pointer == NULL) {
        return FALSE;
    }
    FFRPointer *farframePointer = (FFRPointer *)pointer;
    if (farframePointer->pixels == NULL || farframePointer->bufferLength == 0U) {
        return FALSE;
    }

    const FFRGraphicsEvent event = {
        .type = FFR_GRAPHICS_EVENT_CURSOR_SHAPE,
        .sourceStride = pointer->width * FFR_BYTES_PER_PIXEL,
        .pixels = farframePointer->pixels,
        .bufferLength = farframePointer->bufferLength,
        .cursorWidth = pointer->width,
        .cursorHeight = pointer->height,
        .cursorHotspotX = pointer->xPos,
        .cursorHotspotY = pointer->yPos,
        .sequenceNumber = ++session->graphicsSequenceNumber,
    };
    FFREmitGraphicsEvent(session, &event);
    return TRUE;
}

static BOOL FFRPointerSetNull(rdpContext *context)
{
    FFRSession *session = FFRSessionFromContext(context);
    if (session == NULL) {
        return FALSE;
    }
    const FFRGraphicsEvent event = {
        .type = FFR_GRAPHICS_EVENT_CURSOR_HIDDEN,
        .sequenceNumber = ++session->graphicsSequenceNumber,
    };
    FFREmitGraphicsEvent(session, &event);
    return TRUE;
}

static BOOL FFRPointerSetDefault(rdpContext *context)
{
    FFRSession *session = FFRSessionFromContext(context);
    if (session == NULL) {
        return FALSE;
    }
    const FFRGraphicsEvent event = {
        .type = FFR_GRAPHICS_EVENT_CURSOR_DEFAULT,
        .sequenceNumber = ++session->graphicsSequenceNumber,
    };
    FFREmitGraphicsEvent(session, &event);
    return TRUE;
}

static BOOL FFRPointerSetPosition(rdpContext *context, UINT32 x, UINT32 y)
{
    FFRSession *session = FFRSessionFromContext(context);
    if (session == NULL) {
        return FALSE;
    }
    const FFRGraphicsEvent event = {
        .type = FFR_GRAPHICS_EVENT_CURSOR_POSITION,
        .cursorX = x,
        .cursorY = y,
        .sequenceNumber = ++session->graphicsSequenceNumber,
    };
    FFREmitGraphicsEvent(session, &event);
    return TRUE;
}

static BOOL FFRPostConnect(freerdp *instance)
{
    if (instance == NULL || instance->context == NULL) {
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        return FALSE;
    }

    size_t initialBufferLength = 0U;
    if (!FFRValidateDesktopBuffer(instance->context->gdi,
                                  &initialBufferLength)) {
        gdi_free(instance);
        return FALSE;
    }

    const rdpPointer pointer = {
        .size = sizeof(FFRPointer),
        .New = FFRPointerNew,
        .Free = FFRPointerFree,
        .Set = FFRPointerSet,
        .SetNull = FFRPointerSetNull,
        .SetDefault = FFRPointerSetDefault,
        .SetPosition = FFRPointerSetPosition,
    };
    graphics_register_pointer(instance->context->graphics, &pointer);

    rdpUpdate *update = instance->context->update;
    if (update == NULL) {
        gdi_free(instance);
        return FALSE;
    }
    update->BeginPaint = FFRBeginPaint;
    update->EndPaint = FFREndPaint;
    update->DesktopResize = FFRDesktopResize;

    FFRSession *session = FFRSessionFromInstance(instance);
    if (session == NULL) {
        gdi_free(instance);
        return FALSE;
    }
    const FFRGraphicsEvent event = {
        .type = FFR_GRAPHICS_EVENT_DESKTOP_SIZE,
        .desktopWidth = (uint32_t)instance->context->gdi->width,
        .desktopHeight = (uint32_t)instance->context->gdi->height,
        .sequenceNumber = ++session->graphicsSequenceNumber,
    };
    FFREmitGraphicsEvent(session, &event);
    return TRUE;
}

static void FFRPostDisconnect(freerdp *instance)
{
    gdi_free(instance);
}

bool FFRSessionIsOwnedByCurrentThread(const FFRSession *session)
{
    return session != NULL && pthread_equal(session->ownerThread, pthread_self()) != 0;
}

FFRSession *FFRSessionFromInstance(freerdp *instance)
{
    if (instance == NULL || instance->context == NULL) {
        return NULL;
    }

    FFRRdpContext *context = (FFRRdpContext *)instance->context;
    return context->session;
}

void FFREmitEvent(FFRSession *session,
                  FFREventType type,
                  FFRResult result,
                  FFRConnectionFailure failure,
                  uint32_t nativeErrorCode,
                  const FFRCertificateInfo *certificate)
{
    if (session->callback == NULL) {
        return;
    }

    const FFREvent event = {
        .type = type,
        .result = result,
        .failure = failure,
        .nativeErrorCode = nativeErrorCode,
        .certificate = certificate,
    };
    session->callback(session, &event, session->callbackContext);
}

void FFREmitGraphicsEvent(FFRSession *session, const FFRGraphicsEvent *event)
{
    if (session == NULL || event == NULL || session->graphicsCallback == NULL) {
        return;
    }
    session->graphicsCallback(session, event, session->graphicsCallbackContext);
}

void FFREmitClipboardEvent(FFRSession *session, const FFRClipboardEvent *event)
{
    if (session == NULL || event == NULL || session->clipboardCallback == NULL) {
        return;
    }
    session->clipboardCallback(session, event, session->clipboardCallbackContext);
}

uint32_t FFRBridgeABIVersion(void)
{
    return 15U;
}

const char *FFRFreeRDPVersion(void)
{
    return freerdp_get_version_string();
}

const char *FFRFreeRDPBuildRevision(void)
{
    return freerdp_get_build_revision();
}

const char *FFRResultDescription(FFRResult result)
{
    switch (result) {
    case FFR_RESULT_OK:
        return "ok";
    case FFR_RESULT_INVALID_ARGUMENT:
        return "invalid argument";
    case FFR_RESULT_ALLOCATION_FAILED:
        return "allocation failed";
    case FFR_RESULT_CONTEXT_CREATION_FAILED:
        return "FreeRDP context creation failed";
    case FFR_RESULT_THREAD_VIOLATION:
        return "session owner thread required";
    case FFR_RESULT_INVALID_STATE:
        return "invalid session state";
    case FFR_RESULT_SETTINGS_FAILED:
        return "FreeRDP settings update failed";
    case FFR_RESULT_CONNECTION_FAILED:
        return "RDP connection failed";
    case FFR_RESULT_CANCELLED:
        return "connection cancelled";
    case FFR_RESULT_INPUT_QUEUE_FULL:
        return "input queue is full";
    default:
        return "unknown Bridge result";
    }
}

const char *FFRConnectionFailureDescription(FFRConnectionFailure failure)
{
    switch (failure) {
    case FFR_CONNECTION_FAILURE_NONE:
        return "none";
    case FFR_CONNECTION_FAILURE_DNS:
        return "host name could not be resolved";
    case FFR_CONNECTION_FAILURE_NETWORK:
        return "remote desktop service is unreachable";
    case FFR_CONNECTION_FAILURE_TLS:
        return "TLS connection failed";
    case FFR_CONNECTION_FAILURE_CERTIFICATE_REJECTED:
        return "certificate was rejected";
    case FFR_CONNECTION_FAILURE_CERTIFICATE_CHANGED:
        return "certificate has changed";
    case FFR_CONNECTION_FAILURE_AUTHENTICATION:
        return "authentication failed";
    case FFR_CONNECTION_FAILURE_SERVER_REFUSED:
        return "server refused the connection";
    case FFR_CONNECTION_FAILURE_PROTOCOL:
        return "RDP protocol negotiation failed";
    case FFR_CONNECTION_FAILURE_CANCELLED:
        return "connection cancelled";
    case FFR_CONNECTION_FAILURE_SECURITY_NEGOTIATION:
        return "TLS/NLA security negotiation failed";
    case FFR_CONNECTION_FAILURE_GATEWAY_AUTHENTICATION:
        return "RD Gateway authentication failed";
    case FFR_CONNECTION_FAILURE_GATEWAY_ACCESS_DENIED:
        return "RD Gateway access denied";
    default:
        return "unknown connection failure";
    }
}

FFRResult FFRSessionCreate(FFREventCallback callback,
                           void *userContext,
                           FFRSession **outSession)
{
    if (outSession == NULL) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    *outSession = NULL;

    FFRSession *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        return FFR_RESULT_ALLOCATION_FAILED;
    }

    session->ownerThread = pthread_self();
    atomic_init(&session->cancellationRequested, false);
    atomic_init(&session->connectionActive, false);
    atomic_init(&session->inputEnabled, false);
    session->callback = callback;
    session->callbackContext = userContext;
    session->state = FFR_SESSION_STATE_CREATED;

    if (pthread_mutex_init(&session->decisionMutex, NULL) != 0) {
        free(session);
        return FFR_RESULT_ALLOCATION_FAILED;
    }
    if (pthread_cond_init(&session->decisionCondition, NULL) != 0) {
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_ALLOCATION_FAILED;
    }
    if (pthread_mutex_init(&session->inputMutex, NULL) != 0) {
        pthread_cond_destroy(&session->decisionCondition);
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_ALLOCATION_FAILED;
    }
    if (pthread_mutex_init(&session->clipboardMutex, NULL) != 0) {
        pthread_mutex_destroy(&session->inputMutex);
        pthread_cond_destroy(&session->decisionCondition);
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_ALLOCATION_FAILED;
    }
    session->inputEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (session->inputEvent == NULL) {
        pthread_mutex_destroy(&session->clipboardMutex);
        pthread_mutex_destroy(&session->inputMutex);
        pthread_cond_destroy(&session->decisionCondition);
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_ALLOCATION_FAILED;
    }

    (void)WLog_SetLogLevel(WLog_GetRoot(), WLOG_OFF);
    if (!FFRRegisterChannelAddins()) {
        CloseHandle(session->inputEvent);
        pthread_mutex_destroy(&session->clipboardMutex);
        pthread_mutex_destroy(&session->inputMutex);
        pthread_cond_destroy(&session->decisionCondition);
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_CONTEXT_CREATION_FAILED;
    }
    session->instance = freerdp_new();
    if (session->instance == NULL) {
        CloseHandle(session->inputEvent);
        pthread_mutex_destroy(&session->clipboardMutex);
        pthread_mutex_destroy(&session->inputMutex);
        pthread_cond_destroy(&session->decisionCondition);
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_ALLOCATION_FAILED;
    }

    session->instance->ContextSize = sizeof(FFRRdpContext);
    if (!freerdp_context_new(session->instance)) {
        freerdp_free(session->instance);
        CloseHandle(session->inputEvent);
        pthread_mutex_destroy(&session->clipboardMutex);
        pthread_mutex_destroy(&session->inputMutex);
        pthread_cond_destroy(&session->decisionCondition);
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_CONTEXT_CREATION_FAILED;
    }

    FFRRdpContext *context = (FFRRdpContext *)session->instance->context;
    context->session = session;
    session->instance->PostConnect = FFRPostConnect;
    session->instance->PostDisconnect = FFRPostDisconnect;
    if (PubSub_SubscribeChannelConnected(session->instance->context->pubSub,
                                         FFROnChannelConnected) != CHANNEL_RC_OK ||
        PubSub_SubscribeChannelDisconnected(session->instance->context->pubSub,
                                            FFROnChannelDisconnected) != CHANNEL_RC_OK) {
        freerdp_context_free(session->instance);
        freerdp_free(session->instance);
        CloseHandle(session->inputEvent);
        pthread_mutex_destroy(&session->clipboardMutex);
        pthread_mutex_destroy(&session->inputMutex);
        pthread_cond_destroy(&session->decisionCondition);
        pthread_mutex_destroy(&session->decisionMutex);
        free(session);
        return FFR_RESULT_CONTEXT_CREATION_FAILED;
    }
    atomic_fetch_add_explicit(&g_liveSessionCount, 1, memory_order_relaxed);
    *outSession = session;
    FFREmitEvent(session, FFR_EVENT_SESSION_CREATED, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);
    return FFR_RESULT_OK;
}

FFRResult FFRSessionSetEventCallback(FFRSession *session,
                                     FFREventCallback callback,
                                     void *userContext)
{
    if (session == NULL) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    if (!FFRSessionIsOwnedByCurrentThread(session)) {
        return FFR_RESULT_THREAD_VIOLATION;
    }
    if (session->state == FFR_SESSION_STATE_CONNECTING ||
        session->state == FFR_SESSION_STATE_CONNECTED) {
        return FFR_RESULT_INVALID_STATE;
    }

    session->callback = callback;
    session->callbackContext = userContext;
    return FFR_RESULT_OK;
}

FFRResult FFRSessionSetGraphicsEventCallback(FFRSession *session,
                                             FFRGraphicsEventCallback callback,
                                             void *userContext)
{
    if (session == NULL) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    if (!FFRSessionIsOwnedByCurrentThread(session)) {
        return FFR_RESULT_THREAD_VIOLATION;
    }
    if (session->state == FFR_SESSION_STATE_CONNECTING ||
        session->state == FFR_SESSION_STATE_CONNECTED) {
        return FFR_RESULT_INVALID_STATE;
    }

    session->graphicsCallback = callback;
    session->graphicsCallbackContext = userContext;
    return FFR_RESULT_OK;
}

FFRResult FFRSessionSetClipboardEventCallback(FFRSession *session,
                                              FFRClipboardEventCallback callback,
                                              void *userContext)
{
    if (session == NULL) {
        return FFR_RESULT_INVALID_ARGUMENT;
    }
    if (!FFRSessionIsOwnedByCurrentThread(session)) {
        return FFR_RESULT_THREAD_VIOLATION;
    }
    if (session->state == FFR_SESSION_STATE_CONNECTING ||
        session->state == FFR_SESSION_STATE_CONNECTED) {
        return FFR_RESULT_INVALID_STATE;
    }

    session->clipboardCallback = callback;
    session->clipboardCallbackContext = userContext;
    return FFR_RESULT_OK;
}

bool FFRSessionIsCancellationRequested(const FFRSession *session)
{
    if (session == NULL) {
        return false;
    }
    return atomic_load_explicit(&session->cancellationRequested, memory_order_acquire);
}

bool FFRSessionOwnsCurrentThread(const FFRSession *session)
{
    return FFRSessionIsOwnedByCurrentThread(session);
}

FFRResult FFRSessionDestroy(FFRSession **sessionAddress)
{
    if (sessionAddress == NULL || *sessionAddress == NULL) {
        return FFR_RESULT_OK;
    }

    FFRSession *session = *sessionAddress;
    if (!FFRSessionIsOwnedByCurrentThread(session)) {
        return FFR_RESULT_THREAD_VIOLATION;
    }
    if (session->state == FFR_SESSION_STATE_CONNECTING ||
        session->state == FFR_SESSION_STATE_CONNECTED) {
        return FFR_RESULT_INVALID_STATE;
    }

    FFREmitEvent(session, FFR_EVENT_SESSION_WILL_DESTROY, FFR_RESULT_OK,
                 FFR_CONNECTION_FAILURE_NONE, 0U, NULL);
    session->callback = NULL;
    session->callbackContext = NULL;
    session->graphicsCallback = NULL;
    session->graphicsCallbackContext = NULL;
    session->clipboardCallback = NULL;
    session->clipboardCallbackContext = NULL;
    FFRClearClipboardState(session);

    (void)freerdp_settings_set_string(session->instance->context->settings,
                                      FreeRDP_Password, NULL);
    FFRRdpContext *context = (FFRRdpContext *)session->instance->context;
    context->session = NULL;
    freerdp_context_free(session->instance);
    freerdp_free(session->instance);

    CloseHandle(session->inputEvent);
    pthread_mutex_destroy(&session->clipboardMutex);
    pthread_mutex_destroy(&session->inputMutex);
    pthread_cond_destroy(&session->decisionCondition);
    pthread_mutex_destroy(&session->decisionMutex);
    atomic_fetch_sub_explicit(&g_liveSessionCount, 1, memory_order_relaxed);
    free(session);
    *sessionAddress = NULL;
    return FFR_RESULT_OK;
}

size_t FFRBridgeLiveSessionCount(void)
{
    return atomic_load_explicit(&g_liveSessionCount, memory_order_relaxed);
}

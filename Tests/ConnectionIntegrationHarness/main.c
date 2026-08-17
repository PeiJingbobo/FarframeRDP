#include "FarframeRDPBridge.h"

#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct IntegrationState {
    FFRSession *session;
    atomic_bool certificateRequested;
    atomic_bool certificateResolved;
    atomic_bool connected;
    atomic_bool cancellationSent;
    atomic_bool done;
    atomic_uint failure;
    atomic_uint nativeError;
    atomic_uint desktopSizeEvents;
    atomic_uint frameEvents;
    atomic_uint cursorEvents;
    atomic_bool invalidGraphicsEvent;
    atomic_bool inputSent;
    atomic_bool inputFailed;
    FFRCertificateDecision decision;
    unsigned int cancelDelayMilliseconds;
} IntegrationState;

static void RecordConnectionEvent(FFRSession *session,
                                  const FFREvent *event,
                                  void *context)
{
    IntegrationState *state = context;
    if (session == NULL || event == NULL || state == NULL) {
        return;
    }

    switch (event->type) {
    case FFR_EVENT_CERTIFICATE_REQUESTED:
        atomic_store_explicit(&state->certificateRequested, true, memory_order_release);
        break;
    case FFR_EVENT_CONNECTED:
        atomic_store_explicit(&state->connected, true, memory_order_release);
        break;
    case FFR_EVENT_FAILED:
        atomic_store_explicit(&state->failure, event->failure, memory_order_release);
        atomic_store_explicit(&state->nativeError, event->nativeErrorCode, memory_order_release);
        break;
    default:
        break;
    }
}

static void RecordGraphicsEvent(FFRSession *session,
                                const FFRGraphicsEvent *event,
                                void *context)
{
    IntegrationState *state = context;
    if (session == NULL || event == NULL || state == NULL) {
        return;
    }

    switch (event->type) {
    case FFR_GRAPHICS_EVENT_DESKTOP_SIZE:
        if (event->desktopWidth == 0U || event->desktopHeight == 0U) {
            atomic_store_explicit(&state->invalidGraphicsEvent, true, memory_order_release);
        }
        atomic_fetch_add_explicit(&state->desktopSizeEvents, 1U, memory_order_relaxed);
        break;
    case FFR_GRAPHICS_EVENT_FRAME: {
        const uint64_t right = (uint64_t)(uint32_t)event->dirtyRect.x +
                               event->dirtyRect.width;
        const uint64_t bottom = (uint64_t)(uint32_t)event->dirtyRect.y +
                                event->dirtyRect.height;
        if (event->pixels == NULL || event->bufferLength == 0U ||
            event->dirtyRect.x < 0 || event->dirtyRect.y < 0 ||
            event->dirtyRect.width == 0U || event->dirtyRect.height == 0U ||
            right > event->desktopWidth || bottom > event->desktopHeight) {
            atomic_store_explicit(&state->invalidGraphicsEvent, true, memory_order_release);
        }
        atomic_fetch_add_explicit(&state->frameEvents, 1U, memory_order_relaxed);
        break;
    }
    case FFR_GRAPHICS_EVENT_CURSOR_SHAPE:
    case FFR_GRAPHICS_EVENT_CURSOR_POSITION:
    case FFR_GRAPHICS_EVENT_CURSOR_HIDDEN:
    case FFR_GRAPHICS_EVENT_CURSOR_DEFAULT:
        atomic_fetch_add_explicit(&state->cursorEvents, 1U, memory_order_relaxed);
        break;
    default:
        atomic_store_explicit(&state->invalidGraphicsEvent, true, memory_order_release);
        break;
    }
}

static void *DriveInteractiveDecisions(void *context)
{
    IntegrationState *state = context;

    if (state->cancelDelayMilliseconds > 0U) {
        usleep(state->cancelDelayMilliseconds * 1000U);
        atomic_store_explicit(&state->cancellationSent, true, memory_order_release);
        (void)FFRSessionRequestCancellation(state->session);
    }

    while (!atomic_load_explicit(&state->done, memory_order_acquire)) {
        if (atomic_load_explicit(&state->certificateRequested, memory_order_acquire) &&
            !atomic_exchange_explicit(&state->certificateResolved, true, memory_order_acq_rel)) {
            (void)FFRSessionResolveCertificate(state->session, state->decision);
        }

        if (state->cancelDelayMilliseconds == 0U &&
            atomic_load_explicit(&state->connected, memory_order_acquire) &&
            !atomic_exchange_explicit(&state->cancellationSent, true, memory_order_acq_rel)) {
            /* Exercise only non-text input so the integration run cannot type
               into an unknown remote application. */
            const FFRResult synchronize = FFRSessionSynchronizeLocks(
                state->session, false, false, false);
            const FFRResult move = FFRSessionSendPointerMove(state->session, 0U, 0U);
            atomic_store_explicit(&state->inputSent, true, memory_order_release);
            if (synchronize != FFR_RESULT_OK || move != FFR_RESULT_OK) {
                atomic_store_explicit(&state->inputFailed, true, memory_order_release);
            }
            usleep(100000U);
            if (FFRSessionReleaseAllInput(state->session) != FFR_RESULT_OK) {
                atomic_store_explicit(&state->inputFailed, true, memory_order_release);
            }
            /* Keep consuming graphics long enough to exercise input, GDI and
               pointer callbacks before teardown. */
            usleep(2900000U);
            (void)FFRSessionRequestCancellation(state->session);
        }
        usleep(10000U);
    }
    return NULL;
}

static FFRCertificateDecision ParseDecision(const char *value)
{
    if (value != NULL && strcmp(value, "store") == 0) {
        return FFR_CERTIFICATE_ACCEPT_AND_STORE;
    }
    if (value != NULL && strcmp(value, "once") == 0) {
        return FFR_CERTIFICATE_ACCEPT_FOR_SESSION;
    }
    return FFR_CERTIFICATE_REJECT;
}

static unsigned int ParseDelay(const char *value)
{
    if (value == NULL || *value == '\0') {
        return 0U;
    }
    char *end = NULL;
    const unsigned long parsed = strtoul(value, &end, 10);
    if (end == value || *end != '\0' || parsed > 60000UL) {
        return UINT_MAX;
    }
    return (unsigned int)parsed;
}

int main(void)
{
    const char *host = getenv("FARFRAME_TEST_HOST");
    const char *portText = getenv("FARFRAME_TEST_PORT");
    const char *username = getenv("FARFRAME_TEST_USERNAME");
    const char *domain = getenv("FARFRAME_TEST_DOMAIN");
    const char *password = getenv("FARFRAME_TEST_PASSWORD");
    const char *decisionText = getenv("FARFRAME_TEST_CERTIFICATE_DECISION");
    const unsigned int cancelDelay = ParseDelay(getenv("FARFRAME_TEST_CANCEL_DELAY_MS"));

    if (host == NULL || portText == NULL || username == NULL || domain == NULL ||
        password == NULL || decisionText == NULL || cancelDelay == UINT_MAX) {
        fputs("integration configuration is incomplete\n", stderr);
        return 2;
    }

    char *portEnd = NULL;
    const unsigned long portValue = strtoul(portText, &portEnd, 10);
    if (portEnd == portText || *portEnd != '\0' || portValue == 0UL || portValue > UINT16_MAX) {
        fputs("integration port is invalid\n", stderr);
        return 2;
    }

    IntegrationState state = {
        .session = NULL,
        .decision = ParseDecision(decisionText),
        .cancelDelayMilliseconds = cancelDelay,
    };
    atomic_init(&state.certificateRequested, false);
    atomic_init(&state.certificateResolved, false);
    atomic_init(&state.connected, false);
    atomic_init(&state.cancellationSent, false);
    atomic_init(&state.done, false);
    atomic_init(&state.failure, FFR_CONNECTION_FAILURE_NONE);
    atomic_init(&state.nativeError, 0U);
    atomic_init(&state.desktopSizeEvents, 0U);
    atomic_init(&state.frameEvents, 0U);
    atomic_init(&state.cursorEvents, 0U);
    atomic_init(&state.invalidGraphicsEvent, false);
    atomic_init(&state.inputSent, false);
    atomic_init(&state.inputFailed, false);

    FFRSession *session = NULL;
    if (FFRSessionCreate(RecordConnectionEvent, &state, &session) != FFR_RESULT_OK) {
        fputs("session creation failed\n", stderr);
        return 1;
    }
    state.session = session;
    if (FFRSessionSetGraphicsEventCallback(session, RecordGraphicsEvent, &state) !=
        FFR_RESULT_OK) {
        fputs("graphics callback configuration failed\n", stderr);
        (void)FFRSessionDestroy(&session);
        return 1;
    }

    const FFRConnectionSettings settings = {
        .hostname = host,
        .port = (uint16_t)portValue,
        .username = username,
        .domain = domain,
        .password = password,
        .certificateStorePath = "/tmp/farframe-rdp-integration-certificates",
        .dynamicResolution = true,
        .clipboardText = true,
        .audioPlayback = true,
        .redirectedDirectoryPath = NULL,
        .gatewayHostname = NULL,
        .gatewayPort = 0,
        .gatewayUseSameCredentials = true,
        .gatewayUsername = NULL,
        .gatewayDomain = NULL,
        .gatewayPassword = NULL,
    };
    if (FFRSessionConfigure(session, &settings) != FFR_RESULT_OK) {
        fputs("session configuration failed\n", stderr);
        (void)FFRSessionDestroy(&session);
        return 1;
    }

    pthread_t controlThread;
    if (pthread_create(&controlThread, NULL, DriveInteractiveDecisions, &state) != 0) {
        fputs("control thread creation failed\n", stderr);
        (void)FFRSessionDestroy(&session);
        return 1;
    }

    const FFRResult connectResult = FFRSessionConnect(session);
    const FFRSecurityProtocol negotiatedProtocol =
        FFRSessionNegotiatedSecurityProtocol(session);
    atomic_store_explicit(&state.done, true, memory_order_release);
    (void)pthread_join(controlThread, NULL);
    state.session = NULL;
    (void)FFRSessionDestroy(&session);

    const bool connected = atomic_load_explicit(&state.connected, memory_order_acquire);
    if (cancelDelay > 0U) {
        if (connectResult != FFR_RESULT_CANCELLED || FFRBridgeLiveSessionCount() != 0U) {
            fputs("connecting cancellation or cleanup failed\n", stderr);
            return 1;
        }
        puts("RDP connecting cancellation completed and cleaned up successfully");
        return 0;
    }

    if (!connected) {
        const FFRConnectionFailure failure =
            (FFRConnectionFailure)atomic_load_explicit(&state.failure, memory_order_acquire);
        const unsigned int nativeError =
            atomic_load_explicit(&state.nativeError, memory_order_acquire);
        fprintf(stderr, "connection failed: %s (native 0x%08X)\n",
                FFRConnectionFailureDescription(failure), nativeError);
        return 1;
    }
    const unsigned int desktopSizeEvents =
        atomic_load_explicit(&state.desktopSizeEvents, memory_order_acquire);
    const unsigned int frameEvents =
        atomic_load_explicit(&state.frameEvents, memory_order_acquire);
    if (connectResult != FFR_RESULT_CANCELLED ||
        negotiatedProtocol != FFR_SECURITY_PROTOCOL_NLA ||
        FFRBridgeLiveSessionCount() != 0U ||
        desktopSizeEvents == 0U || frameEvents == 0U ||
        !atomic_load_explicit(&state.inputSent, memory_order_acquire) ||
        atomic_load_explicit(&state.inputFailed, memory_order_acquire) ||
        atomic_load_explicit(&state.invalidGraphicsEvent, memory_order_acquire)) {
        fputs("connection graphics, input, security negotiation, or cleanup failed\n", stderr);
        return 1;
    }

    printf("RDP integration negotiated NLA, delivered non-text input, and consumed %u frame updates safely\n",
           frameEvents);
    return 0;
}

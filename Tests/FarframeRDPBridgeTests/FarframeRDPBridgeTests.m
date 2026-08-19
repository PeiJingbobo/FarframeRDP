#import <XCTest/XCTest.h>
#import "FarframeRDPBridge.h"
#include <string.h>

@interface FarframeRDPBridgeTests : XCTestCase
@end

typedef struct TestEvents {
    NSUInteger created;
    NSUInteger willDestroy;
} TestEvents;

static void RecordEvent(FFRSession *session, const FFREvent *event, void *userContext)
{
    XCTAssertNotEqual(session, NULL);
    XCTAssertNotEqual(event, NULL);
    TestEvents *events = userContext;

    if (event->type == FFR_EVENT_SESSION_CREATED) {
        events->created += 1;
    } else if (event->type == FFR_EVENT_SESSION_WILL_DESTROY) {
        events->willDestroy += 1;
    }
}

@implementation FarframeRDPBridgeTests

- (void)testBridgeAndFreeRDPVersions
{
    XCTAssertEqual(FFRBridgeABIVersion(), 11U);
    XCTAssertEqual(strcmp(FFRFreeRDPVersion(), "3.30.0"), 0);
    XCTAssertTrue(strlen(FFRFreeRDPBuildRevision()) > 0);
}

- (void)testSessionOwnsFreeRDPContextExactlyOnce
{
    const size_t baseline = FFRBridgeLiveSessionCount();

    for (NSUInteger index = 0; index < 250; index += 1) {
        FFRSession *session = NULL;
        XCTAssertEqual(FFRSessionCreate(NULL, NULL, &session), FFR_RESULT_OK);
        XCTAssertNotEqual(session, NULL);
        XCTAssertTrue(FFRSessionOwnsCurrentThread(session));
        XCTAssertEqual(FFRSessionNegotiatedSecurityProtocol(session),
                       FFR_SECURITY_PROTOCOL_UNKNOWN);
        XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
        XCTAssertEqual(session, NULL);
        XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
    }

    XCTAssertEqual(FFRBridgeLiveSessionCount(), baseline);
}

- (void)testCallbackLifetimeAndCancellation
{
    TestEvents events = { 0, 0 };
    FFRSession *session = NULL;

    XCTAssertEqual(FFRSessionCreate(RecordEvent, &events, &session), FFR_RESULT_OK);
    XCTAssertEqual(events.created, 1U);
    XCTAssertFalse(FFRSessionIsCancellationRequested(session));
    XCTAssertEqual(FFRSessionRequestCancellation(session), FFR_RESULT_OK);
    XCTAssertTrue(FFRSessionIsCancellationRequested(session));
    XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
    XCTAssertEqual(events.willDestroy, 1U);
}

- (void)testConnectionSettingsAreValidatedAndCopied
{
    FFRSession *session = NULL;
    XCTAssertEqual(FFRSessionCreate(NULL, NULL, &session), FFR_RESULT_OK);

    const FFRConnectionSettings valid = {
        .hostname = "example.invalid",
        .port = 3389,
        .username = "test-user",
        .domain = "",
        .password = "",
        .certificateStorePath = "/tmp/farframe-rdp-bridge-tests",
        .dynamicResolution = true,
        .clipboardText = true,
        .audioPlayback = true,
        .microphoneRedirection = false,
        .microphoneDeviceName = NULL,
        .redirectedDirectoryPath = NULL,
        .gatewayHostname = NULL,
        .gatewayPort = 0,
        .gatewayUseSameCredentials = true,
        .gatewayUsername = NULL,
        .gatewayDomain = NULL,
        .gatewayPassword = NULL,
    };
    XCTAssertEqual(FFRSessionConfigure(session, &valid), FFR_RESULT_OK);
    XCTAssertTrue(FFRSessionGraphicsPipelineRequested(session));
    XCTAssertEqual(FFRSessionResolveCertificate(session, FFR_CERTIFICATE_REJECT),
                   FFR_RESULT_INVALID_STATE);

    FFRConnectionSettings invalid = valid;
    invalid.hostname = "";
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);
    invalid = valid;
    invalid.port = 0;
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);
    invalid = valid;
    invalid.username = "";
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);
    invalid = valid;
    invalid.redirectedDirectoryPath = "/definitely/not/a/farframe/test/directory";
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);
    invalid = valid;
    invalid.certificateStorePath = NULL;
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);

    XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
}

- (void)testGatewaySettingsAreValidatedAndCopied
{
    FFRSession *session = NULL;
    XCTAssertEqual(FFRSessionCreate(NULL, NULL, &session), FFR_RESULT_OK);

    const FFRConnectionSettings valid = {
        .hostname = "target.example",
        .port = 3389,
        .username = "target-user",
        .domain = "LAB",
        .password = "not-secret-test-value",
        .certificateStorePath = "/tmp/farframe-rdp-bridge-tests",
        .dynamicResolution = true,
        .clipboardText = true,
        .audioPlayback = false,
        .microphoneRedirection = false,
        .microphoneDeviceName = NULL,
        .redirectedDirectoryPath = NULL,
        .gatewayHostname = "gateway.example",
        .gatewayPort = 443,
        .gatewayUseSameCredentials = true,
        .gatewayUsername = NULL,
        .gatewayDomain = NULL,
        .gatewayPassword = NULL,
    };
    XCTAssertEqual(FFRSessionConfigure(session, &valid), FFR_RESULT_OK);
    XCTAssertTrue(FFRSessionGraphicsPipelineRequested(session));
    XCTAssertEqual(strcmp(
                       FFRConnectionFailureDescription(
                           FFR_CONNECTION_FAILURE_GATEWAY_AUTHENTICATION),
                       "RD Gateway authentication failed"),
                   0);
    XCTAssertEqual(strcmp(
                       FFRConnectionFailureDescription(
                           FFR_CONNECTION_FAILURE_GATEWAY_ACCESS_DENIED),
                       "RD Gateway access denied"),
                   0);

    FFRConnectionSettings invalid = valid;
    invalid.gatewayPort = 0;
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);

    invalid = valid;
    invalid.gatewayUseSameCredentials = false;
    invalid.gatewayUsername = "";
    invalid.gatewayDomain = "";
    invalid.gatewayPassword = "";
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);

    XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
}

- (void)testRemoteAppSettingsAreValidatedAndCopied
{
    FFRSession *session = NULL;
    XCTAssertEqual(FFRSessionCreate(NULL, NULL, &session), FFR_RESULT_OK);

    const FFRConnectionSettings valid = {
        .hostname = "target.example",
        .port = 3389,
        .username = "target-user",
        .domain = "",
        .password = "not-secret-test-value",
        .certificateStorePath = "/tmp/farframe-rdp-bridge-tests",
        .dynamicResolution = true,
        .clipboardText = true,
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
        .remoteAppProgram = "||notepad",
        .remoteAppArguments = "",
        .remoteAppWorkingDirectory = "",
    };
    XCTAssertEqual(FFRSessionConfigure(session, &valid), FFR_RESULT_OK);
    XCTAssertFalse(FFRSessionGraphicsPipelineRequested(session));

    FFRConnectionSettings invalid = valid;
    invalid.remoteAppProgram = "";
    XCTAssertEqual(FFRSessionConfigure(session, &invalid), FFR_RESULT_INVALID_ARGUMENT);

    XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
}

- (void)testMicrophoneSettingsAreValidatedAndCopied
{
    FFRSession *session = NULL;
    XCTAssertEqual(FFRSessionCreate(NULL, NULL, &session), FFR_RESULT_OK);

    const FFRConnectionSettings valid = {
        .hostname = "target.example",
        .port = 3389,
        .username = "target-user",
        .domain = "",
        .password = "not-secret-test-value",
        .certificateStorePath = "/tmp/farframe-rdp-bridge-tests",
        .dynamicResolution = false,
        .clipboardText = false,
        .audioPlayback = false,
        .microphoneRedirection = true,
        .microphoneDeviceName = "",
        .redirectedDirectoryPath = NULL,
        .gatewayHostname = NULL,
        .gatewayPort = 0,
        .gatewayUseSameCredentials = true,
        .gatewayUsername = NULL,
        .gatewayDomain = NULL,
        .gatewayPassword = NULL,
    };
    XCTAssertEqual(FFRSessionConfigure(session, &valid), FFR_RESULT_OK);

    XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
}

- (void)testInvalidArgumentsAreSafe
{
    XCTAssertEqual(FFRSessionCreate(NULL, NULL, NULL), FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionRequestCancellation(NULL), FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionSetEventCallback(NULL, NULL, NULL), FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionSetGraphicsEventCallback(NULL, NULL, NULL),
                   FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionSetClipboardEventCallback(NULL, NULL, NULL),
                   FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionPublishClipboardText(NULL, NULL, 0),
                   FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionSendScanCode(NULL, 0x1E, true, false),
                   FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionSendUnicode(NULL, NULL, 0),
                   FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionRequestResize(NULL, 1024, 768),
                   FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionReleaseAllInput(NULL), FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionConfigure(NULL, NULL), FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionConnect(NULL), FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionResolveCertificate(NULL, FFR_CERTIFICATE_REJECT),
                   FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionDestroy(NULL), FFR_RESULT_OK);
    XCTAssertFalse(FFRSessionIsCancellationRequested(NULL));
    XCTAssertFalse(FFRSessionOwnsCurrentThread(NULL));
    XCTAssertEqual(FFRSessionNegotiatedSecurityProtocol(NULL),
                   FFR_SECURITY_PROTOCOL_UNKNOWN);
}

- (void)testResizeRequestsAreValidatedBeforeConnection
{
    FFRSession *session = NULL;
    XCTAssertEqual(FFRSessionCreate(NULL, NULL, &session), FFR_RESULT_OK);
    XCTAssertEqual(FFRSessionRequestResize(session, 1024, 768), FFR_RESULT_INVALID_STATE);
    XCTAssertEqual(FFRSessionRequestResize(session, 199, 768), FFR_RESULT_INVALID_ARGUMENT);
    XCTAssertEqual(FFRSessionRequestResize(session, 1024, 8193), FFR_RESULT_INVALID_ARGUMENT);
    const FFRMonitorLayout twoMonitors[] = {
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
    XCTAssertEqual(FFRSessionRequestMonitorLayout(session, twoMonitors, 2),
                   FFR_RESULT_INVALID_STATE);

    FFRMonitorLayout invalidMonitors[2];
    memcpy(invalidMonitors, twoMonitors, sizeof(invalidMonitors));
    invalidMonitors[0].primary = false;
    XCTAssertEqual(FFRSessionRequestMonitorLayout(session, invalidMonitors, 2),
                   FFR_RESULT_INVALID_ARGUMENT);
    memcpy(invalidMonitors, twoMonitors, sizeof(invalidMonitors));
    invalidMonitors[1].primary = true;
    XCTAssertEqual(FFRSessionRequestMonitorLayout(session, invalidMonitors, 2),
                   FFR_RESULT_INVALID_ARGUMENT);

    FFRMonitorLayout tooMany[17] = {0};
    for (size_t index = 0; index < 17; index += 1) {
        tooMany[index].width = 1024;
        tooMany[index].height = 768;
        tooMany[index].primary = index == 0;
    }
    XCTAssertEqual(FFRSessionRequestMonitorLayout(session, tooMany, 17),
                   FFR_RESULT_INVALID_ARGUMENT);
    const uint16_t text[] = { 'O', 'K' };
    XCTAssertEqual(FFRSessionPublishClipboardText(session, text, 2), FFR_RESULT_INVALID_STATE);
    XCTAssertEqual(FFRSessionDestroy(&session), FFR_RESULT_OK);
}

@end

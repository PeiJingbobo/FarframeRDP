#!/bin/sh

# Release binaries must use the same compiler and SDK that passed real-host
# NLA acceptance. Update these values only together with a fresh acceptance run.
FARFRAME_RELEASE_XCODE_VERSION=26.2
FARFRAME_RELEASE_XCODE_BUILD=17C52
FARFRAME_RELEASE_MACOS_SDK_VERSION=26.2
FARFRAME_RELEASE_XCODE_APP_BASENAME=Xcode_26.2.app

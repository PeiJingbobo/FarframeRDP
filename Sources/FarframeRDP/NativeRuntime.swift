import FarframeRDPBridge

enum NativeRuntime {
    static let freeRDPVersion = String(cString: FFRFreeRDPVersion())
}

package com.example.camera_parent

import io.flutter.plugin.common.MethodChannel

/** Small native-to-Dart bridge used by the foreground service. */
object FlutterServiceBridge {
    private const val CHANNEL = "camera_parent/service"

    /**
     * Returns false while the persistent Flutter engine is not available yet.
     * The service retries instead of assuming a fixed initialization delay.
     */
    fun startAgent(): Boolean {
        val engine = CameraParentApplication.AppHolder.engine ?: return false
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .invokeMethod("startAgent", null)
        return true
    }

    fun stopAgent() {
        val engine = CameraParentApplication.AppHolder.engine ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .invokeMethod("stopAgent", null)
    }
}

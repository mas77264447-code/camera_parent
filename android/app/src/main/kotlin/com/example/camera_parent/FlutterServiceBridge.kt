package com.example.camera_parent

import io.flutter.plugin.common.MethodChannel

object FlutterServiceBridge {
    private const val CHANNEL = "camera_parent/service"

    fun startAgent() {
        val app = CameraParentApplication.AppHolder.engine ?: return
        MethodChannel(app.dartExecutor.binaryMessenger, CHANNEL)
            .invokeMethod("startAgent", null)
    }
}

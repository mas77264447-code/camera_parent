package com.example.camera_parent

import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

object ConnectivityChannel {

    private var channel: MethodChannel? = null

    // آخر حالة معروفة، يسأل عنها Dart عند الإقلاع (الحدث الأول قد يضيع).
    @Volatile
    private var lastOnline: Boolean? = null

    fun setup(engine: FlutterEngine) {
        channel = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "camera_parent/connectivity"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getState" -> result.success(lastOnline)
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun sendNetworkState(online: Boolean) {
        lastOnline = online
        channel?.invokeMethod(
            "networkChanged",
            online
        )
    }
}

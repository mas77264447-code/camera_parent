
package com.example.camera_parent

import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

object ConnectivityChannel {

    private var channel: MethodChannel? = null

    fun setup(engine: FlutterEngine) {
        channel = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "camera_parent/connectivity"
        )
    }

    fun sendNetworkState(online: Boolean) {
        channel?.invokeMethod(
            "networkChanged",
            online
        )
    }
}

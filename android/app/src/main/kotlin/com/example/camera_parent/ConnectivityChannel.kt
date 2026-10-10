
package com.example.camera_parent

import android.os.Handler
import android.os.Looper
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

    private val mainHandler = Handler(Looper.getMainLooper())

    // الإرسال إلى Flutter يجب أن يتم على الخيط الرئيسي، وإلا يتعطل التطبيق
    fun sendNetworkState(online: Boolean) {
        mainHandler.post {
            channel?.invokeMethod(
                "networkChanged",
                online
            )
        }
    }
}

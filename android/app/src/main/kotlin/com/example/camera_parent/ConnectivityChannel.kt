package com.example.camera_parent

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object ConnectivityChannel {
    private const val CHANNEL = "camera_parent/connectivity"
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var pendingState: Boolean? = null

    fun setup(engine: FlutterEngine) {
        synchronized(lock) {
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            val pending = pendingState
            pendingState = null
            if (pending != null) {
                mainHandler.post { channel?.invokeMethod("networkChanged", pending) }
            }
        }
    }

    fun sendNetworkState(online: Boolean) {
        synchronized(lock) {
            val current = channel
            if (current == null) {
                pendingState = online
                return
            }
            mainHandler.post { current.invokeMethod("networkChanged", online) }
        }
    }

    fun clear() {
        synchronized(lock) {
            channel = null
        }
    }
}

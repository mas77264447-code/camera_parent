package com.example.camera_parent

import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

object FlutterServiceBridge {
    private const val TAG = "FlutterServiceBridge"
    private const val CHANNEL = "camera_parent/service_agent"
    private const val ENGINE_ID = CameraParentApplication.ENGINE_ID

    private val lock = Any()
    private var currentChannel: MethodChannel? = null

    @Volatile
    private var agentRunning = false

    fun startAgent() {
        synchronized(lock) {
            if (agentRunning) { Log.d(TAG, "startAgent: already running"); return }
            val engine = ensureEngine() ?: run { Log.e(TAG, "startAgent: no engine"); return }
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            currentChannel = channel
            try {
                channel.invokeMethod("start", null, object : MethodChannel.Result {
                    override fun success(result: Any?) { agentRunning = true; Log.i(TAG, "agent started") }
                    override fun error(code: String, msg: String?, details: Any?) { agentRunning = false; Log.e(TAG, "err $code / $msg") }
                    override fun notImplemented() { agentRunning = false; Log.e(TAG, "not implemented") }
                })
            } catch (e: Exception) { agentRunning = false; Log.e(TAG, "startAgent failed", e) }
        }
    }

    fun stopAgent() {
        synchronized(lock) {
            if (!agentRunning && currentChannel == null) return
            try { currentChannel?.invokeMethod("stop", null) }
            catch (e: Exception) { Log.w(TAG, "stopAgent failed", e) }
            finally { agentRunning = false; currentChannel = null }
        }
    }

    private fun ensureEngine(): FlutterEngine? {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val ctx = CameraParentApplication.appContext() ?: return null
        val app = ctx.applicationContext as? CameraParentApplication ?: return null
        return try { app.ensureEngine() } catch (e: Exception) { Log.e(TAG, "ensureEngine failed", e); null }
    }
}

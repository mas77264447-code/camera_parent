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

    private const val MAX_START_ATTEMPTS = 12
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    fun startAgent() = startAgentAttempt(1)

    // Dart قد لا يكون سجّل الـ handler بعد (Firebase/main لسه يشتغل) فنعيد المحاولة بتأخير متدرج
    private fun startAgentAttempt(attempt: Int) {
        synchronized(lock) {
            if (agentRunning) { Log.d(TAG, "startAgent: already running"); return }
            val engine = ensureEngine() ?: run { Log.e(TAG, "startAgent: no engine"); scheduleRetry(attempt); return }
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            currentChannel = channel
            try {
                channel.invokeMethod("start", null, object : MethodChannel.Result {
                    override fun success(result: Any?) { agentRunning = true; Log.i(TAG, "agent started (attempt=$attempt)") }
                    override fun error(code: String, msg: String?, details: Any?) {
                        agentRunning = false; Log.e(TAG, "err $code / $msg"); scheduleRetry(attempt)
                    }
                    override fun notImplemented() {
                        agentRunning = false; Log.w(TAG, "dart handler not ready yet (attempt=$attempt)"); scheduleRetry(attempt)
                    }
                })
            } catch (e: Exception) { agentRunning = false; Log.e(TAG, "startAgent failed", e); scheduleRetry(attempt) }
        }
    }

    private fun scheduleRetry(attempt: Int) {
        if (attempt >= MAX_START_ATTEMPTS) { Log.e(TAG, "startAgent: giving up after $attempt attempts"); return }
        val delayMs = minOf(500L * attempt, 3000L)
        handler.postDelayed({ startAgentAttempt(attempt + 1) }, delayMs)
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

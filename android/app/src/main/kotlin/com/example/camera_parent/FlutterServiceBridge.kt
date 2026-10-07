package com.example.camera_parent

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

object FlutterServiceBridge {

    private const val TAG = "FlutterServiceBridge"
    private const val CHANNEL = "camera_parent/service_agent"
    private const val ENGINE_ID = CameraParentApplication.ENGINE_ID

    private const val RETRY_DELAY_MS = 500L
    private const val MAX_START_RETRIES = 20

    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var currentChannel: MethodChannel? = null

    @Volatile
    private var agentRunning = false

    @Volatile
    private var startInFlight = false

    private var retryCount = 0

    fun startAgent() {
        synchronized(lock) {
            if (agentRunning) {
                Log.d(TAG, "startAgent: already running")
                return
            }

            if (startInFlight) {
                Log.d(TAG, "startAgent: start already in progress")
                return
            }

            startInFlight = true
            attemptStartLocked()
        }
    }

    private fun attemptStartLocked() {
        val engine = ensureEngine()

        if (engine == null) {
            scheduleRetryLocked("FlutterEngine not ready")
            return
        }

        val channel = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CHANNEL
        )

        currentChannel = channel

        try {
            channel.invokeMethod(
                "start",
                null,
                object : MethodChannel.Result {

                    override fun success(result: Any?) {
                        synchronized(lock) {
                            agentRunning = true
                            startInFlight = false
                            retryCount = 0
                        }
                        Log.i(TAG, "agent started successfully")
                    }

                    override fun error(
                        code: String,
                        msg: String?,
                        details: Any?
                    ) {
                        synchronized(lock) {
                            agentRunning = false
                            scheduleRetryLocked("error $code / $msg")
                        }
                    }

                    override fun notImplemented() {
                        synchronized(lock) {
                            agentRunning = false
                            scheduleRetryLocked(
                                "MethodChannel not implemented yet"
                            )
                        }
                    }
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "startAgent invoke failed", e)
            synchronized(lock) {
                agentRunning = false
                scheduleRetryLocked("exception")
            }
        }
    }

    private fun scheduleRetryLocked(reason: String) {
        if (retryCount >= MAX_START_RETRIES) {
            startInFlight = false
            Log.e(
                TAG,
                "startAgent: giving up after $retryCount retries. reason=$reason"
            )
            return
        }

        retryCount++

        Log.w(
            TAG,
            "startAgent: retry $retryCount/$MAX_START_RETRIES in " +
                "${RETRY_DELAY_MS}ms. reason=$reason"
        )

        mainHandler.postDelayed(
            {
                synchronized(lock) {
                    if (agentRunning) {
                        startInFlight = false
                        return@synchronized
                    }
                    attemptStartLocked()
                }
            },
            RETRY_DELAY_MS
        )
    }

    fun stopAgent() {
        synchronized(lock) {
            mainHandler.removeCallbacksAndMessages(null)

            if (!agentRunning && currentChannel == null) {
                startInFlight = false
                retryCount = 0
                return
            }

            try {
                currentChannel?.invokeMethod("stop", null)
            } catch (e: Exception) {
                Log.w(TAG, "stopAgent failed", e)
            } finally {
                agentRunning = false
                startInFlight = false
                retryCount = 0
                currentChannel = null
            }
        }
    }

    private fun ensureEngine(): FlutterEngine? {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let {
            return it
        }

        val ctx = CameraParentApplication.appContext() ?: return null
        val app = ctx.applicationContext as? CameraParentApplication ?: return null

        return try {
            app.ensureEngine()
        } catch (e: Exception) {
            Log.e(TAG, "ensureEngine failed", e)
            null
        }
    }
}

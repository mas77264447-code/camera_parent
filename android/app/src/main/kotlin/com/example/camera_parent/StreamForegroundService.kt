package com.example.camera_parent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Owns the Android foreground-service lifecycle for camera/screen streaming.
 *
 * Design goals:
 * - startForeground() happens immediately on every valid start request.
 * - Camera and screen modes have separate recovery semantics.
 * - Flutter is notified only after the persistent engine is actually ready;
 *   the bridge retries instead of relying on a fixed 300ms race window.
 * - No attempt is made to bypass Android's camera/microphone/MediaProjection
 *   background-start or consent restrictions.
 */
class StreamForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "camera_parent_stream_channel"
        const val NOTIFICATION_ID = 4821
        const val ACTION_START = "com.example.camera_parent.action.START_STREAM_SERVICE"
        const val ACTION_STOP = "com.example.camera_parent.action.STOP_STREAM_SERVICE"
        const val ACTION_CONFIRM_SCREEN = "com.example.camera_parent.action.CONFIRM_SCREEN_CAPTURE"
        const val EXTRA_MODE = "mode"
        const val MODE_CAMERA = "camera"
        const val MODE_SCREEN = "screen"
        const val KEY_SCREEN_FGS_READY = "screen_fgs_ready"

        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_MODE = "mode"
        private const val KEY_SCREEN_CONFIRMED = "screen_confirmed"
        private const val KEY_RECOVERY_PENDING = "recovery_pending"
        private const val KEY_LAST_ERROR = "last_error"
        private const val AGENT_RETRY_COUNT = 12
        private const val AGENT_RETRY_DELAY_MS = 500L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var agentRetryCount = 0
    private var agentStartRunnable: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONFIRM_SCREEN -> {
                getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putBoolean(KEY_SCREEN_CONFIRMED, true)
                    .putBoolean(KEY_SCREEN_FGS_READY, true)
                    .putBoolean(KEY_RECOVERY_PENDING, false)
                    .remove(KEY_LAST_ERROR)
                    .apply()
                return START_STICKY
            }

            ACTION_STOP -> {
                stopStreaming(startId)
                return START_NOT_STICKY
            }
        }

        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        val mode = intent?.getStringExtra(EXTRA_MODE)
            ?: prefs.getString(KEY_MODE, MODE_CAMERA)
            ?: MODE_CAMERA

        if (mode != MODE_CAMERA && mode != MODE_SCREEN) {
            prefs.edit().putBoolean(KEY_ENABLED, false)
                .putBoolean(KEY_RECOVERY_PENDING, false)
                .putString(KEY_LAST_ERROR, "invalid_mode")
                .apply()
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        // A new explicit start is authoritative for the selected mode.
        // Do not erase screen consent before it is actually needed.
        prefs.edit()
            .putBoolean(KEY_ENABLED, true)
            .putString(KEY_MODE, mode)
            .putBoolean(KEY_RECOVERY_PENDING, false)
            .remove(KEY_LAST_ERROR)
            .apply()

        val notification = buildNotification(mode)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val foregroundType = if (mode == MODE_SCREEN) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIFICATION_ID, notification, foregroundType)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            prefs.edit()
                .putBoolean(KEY_ENABLED, false)
                .putBoolean(KEY_RECOVERY_PENDING, true)
                .putString(KEY_LAST_ERROR, e.javaClass.simpleName)
                .apply()
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        prefs.edit()
            .putBoolean(KEY_SCREEN_FGS_READY, mode == MODE_SCREEN)
            .apply()

        acquireWakeLock()
        scheduleAgentStart(mode)
        return START_STICKY
    }

    private fun scheduleAgentStart(mode: String) {
        agentStartRunnable?.let(handler::removeCallbacks)
        agentRetryCount = 0

        val runnable = object : Runnable {
            override fun run() {
                val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
                val enabled = prefs.getBoolean(KEY_ENABLED, false)
                val currentMode = prefs.getString(KEY_MODE, MODE_CAMERA) ?: MODE_CAMERA
                val screenReady = currentMode != MODE_SCREEN ||
                    prefs.getBoolean(KEY_SCREEN_CONFIRMED, false)

                if (!enabled || currentMode != mode || !screenReady) return

                if (FlutterServiceBridge.startAgent()) {
                    prefs.edit().putBoolean(KEY_RECOVERY_PENDING, false).apply()
                    return
                }

                if (agentRetryCount++ < AGENT_RETRY_COUNT) {
                    handler.postDelayed(this, AGENT_RETRY_DELAY_MS)
                } else {
                    prefs.edit()
                        .putBoolean(KEY_RECOVERY_PENDING, true)
                        .putString(KEY_LAST_ERROR, "flutter_engine_not_ready")
                        .apply()
                }
            }
        }
        agentStartRunnable = runnable
        handler.post(runnable)
    }

    private fun stopStreaming(startId: Int) {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_ENABLED, false)
            .putBoolean(KEY_SCREEN_CONFIRMED, false)
            .putBoolean(KEY_SCREEN_FGS_READY, false)
            .putBoolean(KEY_RECOVERY_PENDING, false)
            .remove(KEY_LAST_ERROR)
            .apply()

        agentStartRunnable?.let(handler::removeCallbacks)
        agentStartRunnable = null
        FlutterServiceBridge.stopAgent()
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelfResult(startId)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "CameraParent::StreamWakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        val mode = prefs.getString(KEY_MODE, MODE_CAMERA) ?: MODE_CAMERA

        if (enabled && mode == MODE_SCREEN) {
            // MediaProjection is a user-consented session. Do not resurrect it
            // after the task is removed.
            prefs.edit()
                .putBoolean(KEY_ENABLED, false)
                .putBoolean(KEY_SCREEN_CONFIRMED, false)
                .putBoolean(KEY_SCREEN_FGS_READY, false)
                .putBoolean(KEY_RECOVERY_PENDING, false)
                .apply()
            releaseWakeLock()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        // Camera mode intentionally remains a foreground-service lifecycle;
        // START_STICKY may allow Android to recreate it.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        agentStartRunnable?.let(handler::removeCallbacks)
        agentStartRunnable = null
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (prefs.getString(KEY_MODE, MODE_CAMERA) == MODE_SCREEN) {
            prefs.edit()
                .putBoolean(KEY_ENABLED, false)
                .putBoolean(KEY_SCREEN_CONFIRMED, false)
                .putBoolean(KEY_SCREEN_FGS_READY, false)
                .apply()
        }
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "بث الكاميرا",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "إشعار خدمة البث في الخلفية"
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(mode: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(if (mode == MODE_SCREEN) "مشاركة الشاشة نشطة" else "بث الكاميرا نشط")
            .setContentText(if (mode == MODE_SCREEN) "مشاركة الشاشة تعمل في الخلفية" else "خدمة الكاميرا تعمل في الخلفية")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .apply { if (pendingIntent != null) setContentIntent(pendingIntent) }
            .setOngoing(true)
            .build()
    }
}

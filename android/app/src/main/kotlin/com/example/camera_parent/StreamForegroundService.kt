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
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class StreamForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "camera_parent_stream_channel"
        const val NOTIFICATION_ID = 4821
        const val ACTION_START = "com.example.camera_parent.action.START_STREAM_SERVICE"
        const val ACTION_STOP = "com.example.camera_parent.action.STOP_STREAM_SERVICE"

        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"

        // Aliases for compatibility with WakeFcmService.kt
        const val EXTRA_MODE = "mode"
        const val MODE_CAMERA = "camera"

        // ✅ Wake polling
        private const val SERVER_URL = "https://camera-parent-server.onrender.com"
        private const val WAKE_CHECK_INTERVAL_MS = 30_000L
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val TAG = "CameraParent"
    }

    private var wakeLock: PowerManager.WakeLock? = null


    // ═══════════════════════════════════════════════════════════
    // Wake Polling — يسأل السيرفر كل 30 ثانية عن طلب إيقاظ
    // ═══════════════════════════════════════════════════════════
    private val handler = Handler(Looper.getMainLooper())

    private val wakeCheckRunnable = object : Runnable {
        override fun run() {
            Thread {
                try {
                    checkServerForWake()
                } catch (e: Exception) {
                    Log.w(TAG, "Wake check error", e)
                }
            }.start()
            handler.postDelayed(this, WAKE_CHECK_INTERVAL_MS)
        }
    }

    private fun checkServerForWake() {
        // device_token موجود في FlutterSharedPreferences
        val flutterPrefs = getSharedPreferences(FLUTTER_PREFS, MODE_PRIVATE)
        val deviceToken = flutterPrefs.getString("flutter.device_token", null)
            ?: return

        val url = URL("$SERVER_URL/wake/check?token=$deviceToken")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = 5000
        conn.readTimeout = 5000

        try {
            val code = conn.responseCode
            if (code != 200) return

            val response = conn.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(response)

            if (json.optBoolean("wake", false)) {
                Log.i(TAG, "🔔 Wake requested! Restarting agent...")
                if (!isStopped()) {
                    handler.post {
                        FlutterServiceBridge.startAgent()
                    }
                }
            }
        } catch (e: Exception) {
            // صامت — أخطاء شبكة عادية
        } finally {
            conn.disconnect()
        }
    }

    private fun startWakePolling() {
        handler.removeCallbacks(wakeCheckRunnable)
        handler.postDelayed(wakeCheckRunnable, WAKE_CHECK_INTERVAL_MS)
        Log.i(TAG, "Wake polling started (every ${WAKE_CHECK_INTERVAL_MS / 1000}s)")
    }

    private fun stopWakePolling() {
        handler.removeCallbacks(wakeCheckRunnable)
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_ENABLED, false)
                .apply()
            FlutterServiceBridge.stopAgent()
            releaseWakeLock()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        // Starting explicitly means the user/app requested the service.
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, true)
            .apply()

        val notification = buildNotification()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Keep the service from crashing repeatedly if the OS rejects an
            // FGS start because of a platform restriction.
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        acquireWakeLock()

        // The Flutter engine is created by CameraParentApplication. Delay the
        // bridge call slightly so the Dart method handler has time to attach.
        android.os.Handler(mainLooper).postDelayed({
            if (!isStopped()) {
                FlutterServiceBridge.startAgent()
            }
        }, 300L)

        // ✅ ابدأ Wake polling
        startWakePolling()

        return START_STICKY
    }

    private fun isStopped(): Boolean =
        !getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_ENABLED, false)

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return

        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK or
            PowerManager.ACQUIRE_CAUSES_WAKEUP or
            PowerManager.ON_AFTER_RELEASE,
            "CameraParent::StreamWakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        Log.i(TAG, "WakeLock acquired (strong)")
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val enabled = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)

        if (enabled) {
            try {
                val restart = Intent(applicationContext, StreamForegroundService::class.java)
                    .setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(restart)
                } else {
                    startService(restart)
                }
            } catch (_: Exception) {
                // START_STICKY remains the platform-level recovery path.
            }
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        // ✅ أوقف Wake polling
        stopWakePolling()
        releaseWakeLock()
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
            channel.description = "إشعار البث المباشر شغال"
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
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
            .setContentTitle("مشاركة الشاشة نشطة")
            .setContentText("خدمة البث تعمل في الخلفية")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .apply { if (pendingIntent != null) setContentIntent(pendingIntent) }
            .setOngoing(true)
            .build()
    }
}

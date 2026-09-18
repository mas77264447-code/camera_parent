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

class StreamForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "camera_parent_stream_channel"
        const val NOTIFICATION_ID = 4821
        const val ACTION_START = "com.example.camera_parent.action.START_STREAM_SERVICE"
        const val ACTION_STOP = "com.example.camera_parent.action.STOP_STREAM_SERVICE"

        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"
    }

    private var wakeLock: PowerManager.WakeLock? = null

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
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        acquireWakeLock()

        Handler(Looper.getMainLooper()).postDelayed({
            if (!isStopped()) {
                FlutterServiceBridge.startAgent()
            }
        }, 300L)

        return START_STICKY
    }

    private fun isStopped(): Boolean =
        !getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_ENABLED, false)

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
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val enabled = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)

        if (enabled) {
            // 1) أعد تشغيل الخدمة (لضمان استمرارية الإشعار)
            try {
                val restart = Intent(applicationContext, StreamForegroundService::class.java)
                    .setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(restart)
                } else {
                    startService(restart)
                }
            } catch (_: Exception) {}

            // 2) ✅ الجديد: أعد فتح الـ MainActivity ليعود التطبيق للواجهة
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                if (launchIntent != null) {
                    launchIntent.addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )
                    startActivity(launchIntent)
                }
            } catch (e: Exception) {
                // Android 10+ قد يمنع هذا بدون SYSTEM_ALERT_WINDOW
            }
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
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
            .setContentTitle("مراقبة نشطة")
            .setContentText("التطبيق يعمل في الخلفية")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .apply { if (pendingIntent != null) setContentIntent(pendingIntent) }
            .setOngoing(true)
            .build()
    }
}

package com.example.camera_parent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class StreamForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "camera_parent_stream_channel"
        const val NOTIFICATION_ID = 4821
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()

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

        acquireWakeLock()

        // Start Dart background agent through the cached FlutterEngine
        FlutterServiceBridge.startAgent()

        return START_STICKY
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return

        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "CameraParent::StreamWakeLock"
        )
        wakeLock?.setReferenceCounted(false)
        wakeLock?.acquire()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val restart = Intent(applicationContext, StreamForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(restart)
        } else {
            startService(restart)
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
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
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("مشاركة الشاشة نشطة")
            .setContentText("جهازك يُشارك شاشته الآن مع حساب الوالد المقترن")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
}

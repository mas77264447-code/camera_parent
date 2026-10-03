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

class StreamForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "camera_parent_stream_channel"
        const val NOTIFICATION_ID = 4821
        const val ACTION_START = "com.example.camera_parent.action.START_STREAM_SERVICE"
        const val ACTION_STOP = "com.example.camera_parent.action.STOP_STREAM_SERVICE"
        const val EXTRA_MODE = "mode"
        const val MODE_CAMERA = "camera"
        const val MODE_MICROPHONE = "microphone"
        const val MODE_SCREEN = "screen"
        const val MODE_FILES = "files"
        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_MODE = "mode"
        private const val WAKELOCK_TIMEOUT_MS = 30 * 60 * 1000L
        private const val WAKELOCK_RENEW_MS = 20 * 60 * 1000L
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val renewHandler = Handler(Looper.getMainLooper())
    private val renewRunnable = object : Runnable {
        override fun run() {
            if (isStopped()) return
            // يمدّد الـ WakeLock قبل انتهاء مهلته (30 دقيقة) حتى لا ينام المعالج ويقطع السيرفر الاتصال
            acquireWakeLock(force = true)
            renewHandler.postDelayed(this, WAKELOCK_RENEW_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        if (action == ACTION_STOP) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, false).apply()
            FlutterServiceBridge.stopAgent()
            renewHandler.removeCallbacks(renewRunnable)
            releaseWakeLock()
            ServiceWatchdog.cancel(this)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        val mode = intent?.getStringExtra(EXTRA_MODE)
            ?: getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_MODE, MODE_CAMERA)
            ?: MODE_CAMERA

        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(KEY_ENABLED, true).putString(KEY_MODE, mode).apply()

        val notification = buildNotification()

        try {
            startForegroundCompat(notification, mode)
        } catch (e: Exception) {
            Log.e("CameraParent", "startForeground failed mode=$mode", e)
            // مثال: رفض المستخدم إذن المايك أو قيود Android 14 → جرّب الكاميرا فقط
            var recovered = false
            if (mode == MODE_CAMERA && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
                    recovered = true
                } catch (e2: Exception) {
                    Log.e("CameraParent", "camera-only startForeground failed", e2)
                }
            }
            if (!recovered) {
                // لا نترك enabled=true بعد فشل البدء حتى لا يعيد BootReceiver المحاولة بصمت
                getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putBoolean(KEY_ENABLED, false)
                    .putString("last_fgs_error", (e.message ?: e.javaClass.simpleName))
                    .apply()
                stopSelfResult(startId)
                return START_NOT_STICKY
            }
        }

        acquireWakeLock()
        renewHandler.removeCallbacks(renewRunnable)
        renewHandler.postDelayed(renewRunnable, WAKELOCK_RENEW_MS)
        ServiceWatchdog.scheduleNext(this)

        Handler(Looper.getMainLooper()).postDelayed({
            if (!isStopped()) FlutterServiceBridge.startAgent()
        }, 300L)

        return START_STICKY
    }

    private fun isStopped(): Boolean =
        !getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_ENABLED, false)

    private fun startForegroundCompat(notification: Notification, mode: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = when (mode) {
                MODE_SCREEN -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                MODE_MICROPHONE -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                MODE_FILES -> 0
                else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (type == 0) startForeground(NOTIFICATION_ID, notification)
            else startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock(force: Boolean = false) {
        val existing = wakeLock
        if (existing != null) {
            // نفس الكائن: acquire مع مهلة جديدة يمدّد القفل بدل إنشاء قفل ثانٍ يتسرّب
            if (force || !existing.isHeld) existing.acquire(WAKELOCK_TIMEOUT_MS)
            return
        }
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CameraParent::StreamWakeLock").apply {
            setReferenceCounted(false)
            acquire(WAKELOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val enabled = getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_ENABLED, false)
        if (enabled) {
            try {
                val restart = Intent(applicationContext, StreamForegroundService::class.java).setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(restart)
                else startService(restart)
            } catch (e: Exception) {
                Log.w("CameraParent", "onTaskRemoved: unable to restart FGS", e)
            }
            ServiceWatchdog.scheduleNext(applicationContext, 10_000L)
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        renewHandler.removeCallbacks(renewRunnable)
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "بث الكاميرا", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "إشعار البث المباشر شغال" }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
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

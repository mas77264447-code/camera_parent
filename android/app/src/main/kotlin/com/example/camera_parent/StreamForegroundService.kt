package com.example.camera_parent

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

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

        private const val START_AGENT_DELAY_MS = 2500L
        private val RETRY_DELAYS_MS = longArrayOf(2500L, 5000L, 10000L)

        private const val RESTART_ALARM_DELAY_MS = 3000L
        private const val RESTART_REQUEST_CODE = 4822

        private const val TAG = "CameraParent"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var foregroundStarted = false
    private var retryIndex = 0
    private val handler = Handler(Looper.getMainLooper())

    private val startAgentRunnable = Runnable {
        if (isStopped()) {
            Log.i(TAG, "startAgent skipped: service stopped")
            return@Runnable
        }

        val ready = try {
            FlutterServiceBridge.isAgentReady()
        } catch (e: Throwable) {
            Log.w(TAG, "isAgentReady() threw, assuming not ready", e)
            false
        }

        if (!ready) {
            Log.w(TAG, "Flutter agent not ready yet (attempt ${retryIndex + 1})")
            scheduleAgentRetry()
            return@Runnable
        }

        try {
            FlutterServiceBridge.startAgent()
            retryIndex = 0
            Log.i(TAG, "Flutter agent startAgent() invoked successfully")
        } catch (e: Throwable) {
            Log.e(TAG, "startAgent() failed, will retry", e)
            scheduleAgentRetry()
        }
    }

    private fun scheduleAgentRetry() {
        if (retryIndex >= RETRY_DELAYS_MS.size) {
            Log.e(TAG, "All agent retries exhausted. Camera stream will not start.")
            return
        }
        val delay = RETRY_DELAYS_MS[retryIndex]
        retryIndex++
        handler.removeCallbacks(startAgentRunnable)
        handler.postDelayed(startAgentRunnable, delay)
        Log.i(TAG, "Scheduled agent retry #$retryIndex in ${delay}ms")
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        if (action == ACTION_STOP) {
            Log.i(TAG, "Stop action received")
            setEnabled(false)
            handler.removeCallbacks(startAgentRunnable)
            cancelRestartAlarm()
            try { FlutterServiceBridge.stopAgent() } catch (e: Throwable) {
                Log.w(TAG, "stopAgent() failed", e)
            }
            releaseWakeLock()
            ServiceWatchdog.cancel(this)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        val mode = intent?.getStringExtra(EXTRA_MODE)
            ?: prefs.getString(KEY_MODE, MODE_CAMERA)
            ?: MODE_CAMERA

        if (!hasRequiredPermissions(mode)) {
            Log.e(TAG, "Missing permissions for mode=$mode - aborting service start")
            setEnabled(false)
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        if (Build.VERSION.SDK_INT >= 35 && mode == MODE_CAMERA) {
            Log.w(TAG, "Android 15+: camera FGS from BOOT_COMPLETED may be blocked by system")
        }

        prefs.edit().putBoolean(KEY_ENABLED, true).putString(KEY_MODE, mode).apply()

        val notification = buildNotification()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = when (mode) {
                    MODE_SCREEN -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                    MODE_MICROPHONE -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    MODE_FILES -> 0
                    else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                if (type == 0) startForeground(NOTIFICATION_ID, notification)
                else startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.i(TAG, "Foreground started, mode=$mode")
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed mode=$mode", e)
            if (foregroundStarted) {
                return START_STICKY
            }
            setEnabled(false)
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        foregroundStarted = true

        acquireWakeLock()
        ServiceWatchdog.scheduleNext(this)

        retryIndex = 0
        handler.removeCallbacks(startAgentRunnable)
        handler.postDelayed(startAgentRunnable, START_AGENT_DELAY_MS)
        Log.i(TAG, "Agent start scheduled in ${START_AGENT_DELAY_MS}ms")

        return START_STICKY
    }

    private fun hasRequiredPermissions(mode: String): Boolean {
        val needsCamera = mode == MODE_CAMERA
        val needsMic = mode == MODE_CAMERA || mode == MODE_MICROPHONE

        if (needsCamera &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "CAMERA permission not granted")
            return false
        }

        if (needsMic &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "RECORD_AUDIO permission not granted")
            return false
        }

        return true
    }

    private fun setEnabled(enabled: Boolean) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    private fun isStopped(): Boolean =
        !getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_ENABLED, false)

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CameraParent::StreamWakeLock").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun restartPendingIntent(): PendingIntent {
        val restart = Intent(applicationContext, StreamForegroundService::class.java).setAction(ACTION_START)
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(applicationContext, RESTART_REQUEST_CODE, restart, flags)
        } else {
            PendingIntent.getService(applicationContext, RESTART_REQUEST_CODE, restart, flags)
        }
    }

    private fun scheduleRestartAlarm() {
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        try {
            am.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + RESTART_ALARM_DELAY_MS,
                restartPendingIntent()
            )
            Log.i(TAG, "Restart alarm scheduled in ${RESTART_ALARM_DELAY_MS}ms")
        } catch (e: Exception) {
            Log.w(TAG, "scheduleRestartAlarm failed", e)
        }
    }

    private fun cancelRestartAlarm() {
        try {
            val am = getSystemService(ALARM_SERVICE) as AlarmManager
            am.cancel(restartPendingIntent())
        } catch (e: Exception) {
            Log.w(TAG, "cancelRestartAlarm failed", e)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!isStopped()) {
            Log.i(TAG, "onTaskRemoved: scheduling restart via alarm & watchdog")
            scheduleRestartAlarm()
            ServiceWatchdog.scheduleNext(applicationContext, 10_000L)
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacks(startAgentRunnable)
        releaseWakeLock()
        Log.i(TAG, "onDestroy: service destroyed")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "بث الكاميرا",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "إشعار البث المباشر شغال" }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
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

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
            ?: prefs.getString(KEY_MODE, MODE_CAMERA)!!

        prefs.edit().putBoolean(KEY_ENABLED, true).putString(KEY_MODE, mode).apply()

        val notification = buildNotification()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = when (mode) {
                    MODE_SCREEN -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                    MODE_MICROPHONE -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    MODE_FILES -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIFICATION_ID, notification, type)
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
        renewHandler.removeCallbacks(renewRunnable)
        renewHandler.postDelayed(renewRunnable, WAKELOCK_RENEW_MS)
        ServiceWatchdog.scheduleNext(this)

        handler.removeCallbacks(startAgentRunnable)
        handler.postDelayed(startAgentRunnable, START_AGENT_DELAY_MS)
        Log.i(TAG, "Agent start scheduled in ${START_AGENT_DELAY_MS}ms")

        // ✅ ابدأ Wake polling
        startWakePolling()

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
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit().putBoolean(KEY_ENABLED, enabled).apply()
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
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "CameraParent::StreamWakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        Log.i(TAG, "WakeLock acquired (strong)")
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun restartPendingIntent(): PendingIntent {
        val restart = Intent(applicationContext, StreamForegroundService::class.java)
            .setAction(ACTION_START)
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                applicationContext, RESTART_REQUEST_CODE, restart, flags
            )
        } else {
            PendingIntent.getService(
                applicationContext, RESTART_REQUEST_CODE, restart, flags
            )
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
            // لا نفتح MainActivity (محظور A10+).
            // START_STICKY + AlarmManager يتولّيان الإحياء.
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
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
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

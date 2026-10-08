package com.example.camera_parent

import android.app.AlarmManager
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
import android.os.SystemClock
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
        // تأخير تشغيل الوكيل بعد startForeground، ليكون ServiceAgentChannel جاهزاً على الأجهزة البطيئة
        private const val START_AGENT_DELAY_MS = 2500L
        // مهلة إعادة التشغيل عبر AlarmManager بعد سحب التطبيق من الحالات الأخيرة
        private const val RESTART_ALARM_DELAY_MS = 3000L
        private const val RESTART_REQUEST_CODE = 4822
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var foregroundStarted = false
    private val handler = Handler(Looper.getMainLooper())
    private val startAgentRunnable = Runnable {
        if (!isStopped()) FlutterServiceBridge.startAgent()
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        if (action == ACTION_STOP) {
            setEnabled(false)
            handler.removeCallbacks(startAgentRunnable)
            cancelRestartAlarm()
            FlutterServiceBridge.stopAgent()
            releaseWakeLock()
            ServiceWatchdog.cancel(this)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        // getString مع قيمة افتراضية لا يُرجع null، فلا حاجة لـ elvis إضافي
        val mode = intent?.getStringExtra(EXTRA_MODE) ?: prefs.getString(KEY_MODE, MODE_CAMERA)!!

        val notification = buildNotification()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = when (mode) {
                    MODE_SCREEN -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                    MODE_MICROPHONE -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    // MODE_FILES: نمرر 0 فيستخدم النظام الأنواع المعلنة في المانيفست
                    MODE_FILES -> 0
                    else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                if (type == 0) startForeground(NOTIFICATION_ID, notification)
                else startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e("CameraParent", "startForeground failed mode=$mode", e)
            if (foregroundStarted) {
                // الخدمة تعمل أصلاً كخدمة أمامية: لا نوقفها بسبب فشل إعادة الترقية
                return START_STICKY
            }
            // فشلت البداية: لا نغيّر حالة "enabled" المحفوظة (فشل مؤقت لا يلغي نية المراقبة)
            // ولا نحفظ الوضع المطلوب لأنه لم يُفعَّل
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        foregroundStarted = true
        // لا نحفظ الوضع والتفعيل إلا بعد نجاح startForeground
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(KEY_ENABLED, true)
            .putString(KEY_MODE, mode)
            .apply()

        acquireWakeLock()
        ServiceWatchdog.scheduleNext(this)

        // إلغاء أي تشغيل معلّق سابق لمنع تشغيل الوكيل أكثر من مرة
        handler.removeCallbacks(startAgentRunnable)
        handler.postDelayed(startAgentRunnable, START_AGENT_DELAY_MS)

        return START_STICKY
    }

    private fun setEnabled(enabled: Boolean) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    private fun isStopped(): Boolean =
        !getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(KEY_ENABLED, false)

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        // بدون مهلة زمنية: يبقى مُمسكاً طوال البث ويُحرَّر فقط عند الإيقاف أو التدمير
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CameraParent::StreamWakeLock").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // PendingIntent ثابت لإعادة التشغيل، يُستخدم للجدولة وللإلغاء
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
        } catch (e: Exception) {
            Log.w("CameraParent", "scheduleRestartAlarm failed", e)
        }
    }

    private fun cancelRestartAlarm() {
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        am.cancel(restartPendingIntent())
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!isStopped()) {
            // 1) إعادة فتح الواجهة قدر الإمكان (قد يمنعها Android 10+ من الخلفية، لذلك لا نعتمد عليها وحدها)
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
                Log.w("CameraParent", "onTaskRemoved: unable to relaunch activity", e)
            }

            // 2) جدولة إعادة تشغيل الخدمة عبر AlarmManager، لأن postDelayed قد لا يُنفَّذ إذا قُتلت العملية
            scheduleRestartAlarm()
            ServiceWatchdog.scheduleNext(applicationContext, 10_000L)
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacks(startAgentRunnable)
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

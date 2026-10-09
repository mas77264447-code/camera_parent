package com.example.camera_parent

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON" &&
            intent.action != "com.htc.intent.action.QUICKBOOT_POWERON") return

        val prefs = context.getSharedPreferences("camera_parent_service", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("enabled", false)
        if (!enabled) return

        // أندرويد 14+ يمنع بدء خدمة الكاميرا من الإقلاع، فلا نحاول:
        // نعرض إشعاراً ينقل المستخدم لفتح التطبيق، ومن هناك تبدأ الخدمة والاتصال.
        if (Build.VERSION.SDK_INT >= 34) {
            postBootNotification(context)
            return
        }

        val mode = prefs.getString("mode", StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA

        try {
            // ✅ 1) افتح MainActivity مؤقتاً — ضروري لفتح الكاميرا من الخلفية
            val warmup = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
                )
                putExtra("from_boot", true)
            }
            context.startActivity(warmup)
            Log.i("CameraParent", "Boot: MainActivity launched for camera warmup")

            // ✅ 2) شغّل Foreground Service
            val service = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, mode)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }

            ServiceWatchdog.scheduleNext(context, 60_000L)
        } catch (e: Exception) {
            Log.w("CameraParent", "Boot recovery start failed", e)
        }
    }

    private fun postBootNotification(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        BOOT_CHANNEL_ID,
                        "تفعيل بعد الإقلاع",
                        NotificationManager.IMPORTANCE_HIGH
                    )
                )
            }
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName) ?: return
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val pending = PendingIntent.getActivity(
                context,
                BOOT_REQUEST_CODE,
                launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val notif = NotificationCompat.Builder(context, BOOT_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle("المراقبة متوقفة بعد إعادة التشغيل")
                .setContentText("اضغط هنا لتفعيل المراقبة")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()
            nm.notify(BOOT_NOTIFICATION_ID, notif)
        } catch (e: Exception) {
            Log.w("CameraParent", "boot notification failed", e)
        }
    }

    companion object {
        private const val BOOT_CHANNEL_ID = "camera_boot_start"
        private const val BOOT_NOTIFICATION_ID = 9997
        private const val BOOT_REQUEST_CODE = 7001
    }
}

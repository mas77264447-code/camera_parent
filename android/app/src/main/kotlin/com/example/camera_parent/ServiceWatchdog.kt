package com.example.camera_parent

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

object ServiceWatchdog {
    private const val TAG = "ServiceWatchdog"
    private const val INTERVAL_MS = 60 * 1000L
    private const val REQUEST_CODE = 7788
    const val ACTION = "com.example.camera_parent.WATCHDOG"

    /// ✅ إصلاح: استخدام set() بدل setExact() لتقليل استهلاك البطارية.
    /// set() يسمح للنظام بتأجيل التنبيه قليلاً، لكنه لا يستدعي RTC_WAKEUP
    /// من النوم العميق بشكل متكرر → عمر بطارية أفضل + تجنّب قتل MIUI.
    fun scheduleNext(context: Context, delayMs: Long = INTERVAL_MS) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, ServiceWatchdogReceiver::class.java).apply {
                action = ACTION
            }
            val pi = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val triggerAt = System.currentTimeMillis() + delayMs

            // ✅ إصلاح: استخدام set() بدل setExact/setExactAndAllowWhileIdle
            // لتقليل الاستهلاك. Watchdog "تقريبي" كافٍ لإعادة الخدمة.
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    // setAndAllowWhileIdle يسمح بالعمل في Doze mode لكن لا يوقظ
                    // المعالج بعنف (بخلاف setExactAndAllowWhileIdle).
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
                } else {
                    am.set(AlarmManager.RTC_WAKEUP, triggerAt, pi)
                }
            } catch (se: SecurityException) {
                // fallback
                am.set(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            }

            Log.d(TAG, "Next watchdog in ${delayMs / 1000}s")
        } catch (e: Exception) {
            Log.e(TAG, "scheduleNext failed: ${e.message}", e)
        }
    }

    fun cancel(context: Context) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, ServiceWatchdogReceiver::class.java).apply {
                action = ACTION
            }
            val pi = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            am.cancel(pi)
        } catch (_: Exception) {}
    }
}
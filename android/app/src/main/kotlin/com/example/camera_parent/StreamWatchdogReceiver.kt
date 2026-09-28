package com.example.camera_parent

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log

/**
 * Non-invasive recovery watchdog.
 *
 * IMPORTANT: this receiver deliberately does NOT start the camera foreground
 * service from an alarm. Modern Android restricts background starts of camera
 * and microphone FGS types, especially on Android 14+. Trying to work around
 * that restriction from AlarmManager can result in SecurityException or
 * ForegroundServiceStartNotAllowedException.
 *
 * The real recovery mechanism is StreamForegroundService.START_STICKY with
 * stopWithTask=false. Android may recreate a killed service. This watchdog is
 * only a lightweight heartbeat marker that can be used for diagnostics and to
 * keep a recovery intent scheduled without attempting a prohibited background
 * camera start.
 */
class StreamWatchdogReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_WATCHDOG = "com.example.camera_parent.action.STREAM_WATCHDOG"
        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_MODE = "mode"
        private const val KEY_LAST_HEARTBEAT = "watchdog_last_heartbeat"
        private const val REQUEST_CODE = 48721
        private const val INTERVAL_MS = 15 * 60 * 1000L

        fun schedule(context: Context, delayMs: Long = INTERVAL_MS) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = pendingIntent(context)
            val triggerAt = SystemClock.elapsedRealtime() + delayMs

            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAt,
                pendingIntent
            )
        }

        fun cancel(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(pendingIntent(context))
        }

        private fun pendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, StreamWatchdogReceiver::class.java)
                .setAction(ACTION_WATCHDOG)
            return PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_WATCHDOG) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        val mode = prefs.getString(KEY_MODE, StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA

        if (!enabled || mode != StreamForegroundService.MODE_CAMERA) {
            cancel(context)
            return
        }

        prefs.edit()
            .putLong(KEY_LAST_HEARTBEAT, System.currentTimeMillis())
            .apply()

        Log.d(
            "CameraParent",
            "Watchdog heartbeat recorded; camera FGS restart is left to Android START_STICKY lifecycle."
        )

        schedule(context)
    }
}

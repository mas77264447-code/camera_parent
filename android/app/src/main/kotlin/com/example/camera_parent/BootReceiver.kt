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

/**
 * Restores service state after boot where Android permits the requested FGS
 * start. Modern Android versions restrict boot-time starts of camera,
 * microphone and MediaProjection foreground services, so this receiver never
 * attempts to bypass those restrictions.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "CameraParent"
        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_MODE = "mode"
        private const val KEY_RECOVERY_PENDING = "recovery_pending"
        private const val RECOVERY_CHANNEL = "camera_parent_recovery"
        private const val RECOVERY_NOTIFICATION_ID = 4822
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        if (!enabled) return

        val mode = prefs.getString(KEY_MODE, StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA

        // Android 14+ restricts starting camera/microphone/mediaProjection FGS
        // from BOOT_COMPLETED. Keep the state and surface a clear recovery path.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            prefs.edit().putBoolean(KEY_RECOVERY_PENDING, true).apply()
            Log.i(TAG, "Boot recovery deferred by Android restrictions (mode=$mode)")
            showRecoveryNotification(context, mode)
            return
        }

        try {
            val service = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, mode)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (e: Exception) {
            prefs.edit()
                .putBoolean(KEY_RECOVERY_PENDING, true)
                .apply()
            Log.w(TAG, "Unable to restore foreground service after boot", e)
            showRecoveryNotification(context, mode)
        }
    }

    private fun showRecoveryNotification(context: Context, mode: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    RECOVERY_CHANNEL,
                    "استعادة Camera",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val text = if (mode == StreamForegroundService.MODE_SCREEN) {
            "أعد فتح التطبيق لإعادة بدء مشاركة الشاشة بعد موافقة Android."
        } else {
            "أعد فتح التطبيق لاستكمال استعادة خدمة الكاميرا بعد إعادة التشغيل."
        }

        manager.notify(
            RECOVERY_NOTIFICATION_ID,
            NotificationCompat.Builder(context, RECOVERY_CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle("Camera يحتاج استكمال الاستعادة")
                .setContentText(text)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()
        )
    }
}

package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "CameraParent"
        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_MODE = "mode"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return

        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON") {
            return
        }

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        if (!enabled) {
            Log.i(TAG, "Boot: service disabled, skip")
            return
        }

        val mode = prefs.getString(KEY_MODE, StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA
        BootLog.w("enabled=$enabled mode=$mode overlay=${Settings.canDrawOverlays(context)}")
        if (!enabled) { BootLog.w("STOP: enabled=false"); return }

        Log.i(TAG, "Boot: starting FGS mode=$mode")

        // ✅ 1) افتح MainActivity لفترة قصيرة — ضروري لإنتاج إطارات الكاميرا
        //    على Android 14+ (بدونها الكاميرا تُفتح لكن بلا إطارات).
        //    startActivity من BroadcastReceiver يعمل فقط إذا:
        //      - SYSTEM_ALERT_WINDOW مفعّلة، أو
        //      - Device Owner، أو
        //      - Android 13 وأقل.
        try {
            val canDrawOverlays = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Settings.canDrawOverlays(context)
            } else true

            if (canDrawOverlays || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
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
                Log.i(TAG, "Boot: MainActivity warmup launched (overlay OK)")
            } else {
                Log.w(TAG, "Boot: cannot open MainActivity (no overlay, A10+) — camera will try background")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Boot: MainActivity warmup failed: ${e.message}")
        }

        // ✅ 2) شغّل FGS
        try {
            val w = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                putExtra("from_boot", true)
            }
            context.startActivity(w)
            BootLog.w("startActivity called")
        } catch (e: Exception) { BootLog.w("startActivity failed: $e") }

        try {
            val s = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, mode)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }

            ContextCompat.startForegroundService(context, service)
            ServiceWatchdog.scheduleNext(context, 60_000L)
        } catch (e: Exception) {
            Log.w(TAG, "Boot: FGS start failed: ${e.message}")
        }
    }
}

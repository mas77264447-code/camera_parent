package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val enabled = context
            .getSharedPreferences("camera_parent_service", Context.MODE_PRIVATE)
            .getBoolean("enabled", false)

        if (!enabled) return

        try {
            val service = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }

            // ✅ جدول watchdog بعد الإقلاع بـ 60 ثانية
            ServiceWatchdog.scheduleNext(context, 60_000L)

        } catch (e: Exception) {
            Log.w("CameraParent", "Unable to restore foreground service after boot", e)
        }
    }
}
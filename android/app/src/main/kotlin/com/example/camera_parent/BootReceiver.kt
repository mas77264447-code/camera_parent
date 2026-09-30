package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences("camera_parent_service", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("enabled", false)
        if (!enabled) return

        val mode = prefs.getString("mode", StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA

        try {
            val service = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, mode)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(service)
            else context.startService(service)
            ServiceWatchdog.scheduleNext(context, 60_000L)
        } catch (e: Exception) {
            Log.w("CameraParent", "Boot recovery start failed", e)
        }
    }
}

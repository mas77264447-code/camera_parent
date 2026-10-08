package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val a = intent.action
        BootLog.w("receiver got $a sdk=${Build.VERSION.SDK_INT}")
        if (a != Intent.ACTION_BOOT_COMPLETED &&
            a != "android.intent.action.QUICKBOOT_POWERON" &&
            a != "com.htc.intent.action.QUICKBOOT_POWERON") return

        val p = context.getSharedPreferences("camera_parent_service", Context.MODE_PRIVATE)
        val enabled = p.getBoolean("enabled", false)
        val mode = p.getString("mode", StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA
        BootLog.w("enabled=$enabled mode=$mode overlay=${Settings.canDrawOverlays(context)}")
        if (!enabled) { BootLog.w("STOP: enabled=false"); return }

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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(s)
            else context.startService(s)
            BootLog.w("service start requested")
            ServiceWatchdog.scheduleNext(context, 60_000L)
        } catch (e: Exception) { BootLog.w("service start failed: $e") }
    }
}

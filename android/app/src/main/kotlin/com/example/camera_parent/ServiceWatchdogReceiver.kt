package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class ServiceWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ServiceWatchdog.ACTION) return
        Log.d("ServiceWatchdog", "Receiver triggered")

        ServiceWatchdog.scheduleNext(context)

        val enabled = context
            .getSharedPreferences("camera_parent_service", Context.MODE_PRIVATE)
            .getBoolean("enabled", false)
        if (!enabled) return

        try {
            val serviceIntent = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.d("ServiceWatchdog", "Service restart requested")
        } catch (e: Exception) {
            Log.e("ServiceWatchdog", "Restart failed: ${e.message}", e)
        }
    }
}
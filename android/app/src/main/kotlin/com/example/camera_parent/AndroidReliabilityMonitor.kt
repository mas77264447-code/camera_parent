package com.example.camera_parent

import android.app.ActivityManager
import android.content.Context
import android.os.PowerManager

object AndroidReliabilityMonitor {

    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    fun isServiceProcessAlive(context: Context): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val processes = manager.runningAppProcesses ?: return false
        return processes.any { it.processName == context.packageName }
    }
}

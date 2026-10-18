package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log

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
            action != "com.htc.intent.action.QUICKBOOT_POWERON") return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ENABLED, false)) {
            Log.i(TAG, "Boot: service disabled, skip")
            return
        }

        val mode = prefs.getString(KEY_MODE, StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA

        if (Build.VERSION.SDK_INT >= 34) {
            Log.i(TAG, "Boot: A14+ — warmup only (FGS from foreground)")
            startWarmup(context)
            return
        }

        Log.i(TAG, "Boot: pre-A14 — warmup + FGS mode=$mode")
        startWarmup(context)
        startFgs(context, mode)
    }

    private fun startWarmup(context: Context) {
        try {
            val canOverlay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                Settings.canDrawOverlays(context) else true
            if (!canOverlay && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Log.w(TAG, "Boot: no overlay (A10+) — cannot start MainActivity")
                return
            }
            val warmup = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                putExtra("from_boot", true)
            }
            context.startActivity(warmup)
            Log.i(TAG, "Boot: MainActivity warmup launched")
        } catch (e: Exception) {
            Log.w(TAG, "Boot: warmup failed: ${e.message}")
        }
    }

    private fun startFgs(context: Context, mode: String) {
        try {
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
            Log.w(TAG, "Boot: FGS start failed: ${e.message}")
        }
    }
}

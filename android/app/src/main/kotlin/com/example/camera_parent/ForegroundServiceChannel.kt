package com.example.camera_parent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel "camera_parent/foreground_service"
 *
 * نسخة الطوارئ المسجلة في Application (قبل أي Activity).
 * ضرورية عند الإقلاع من BootReceiver حيث MainActivity لم تبدأ بعد.
 *
 * عندما تنشأ MainActivity، ستستبدل هذه القناة بنسخة أقوى.
 * لا تعارض — كلاهما يعمل في سياقه.
 */
object ForegroundServiceChannel {

    private const val TAG = "FgServiceChannel"
    private const val CHANNEL = "camera_parent/foreground_service"

    private const val WAKE_CHANNEL_ID = "camera_wake_channel_boot"
    private const val WAKE_NOTIFICATION_ID = 9998

    fun setup(engine: FlutterEngine, appContext: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "start" -> {
                        try {
                            val mode = call.argument<String>("mode") ?: "camera"
                            val intent = Intent(appContext, StreamForegroundService::class.java)
                                .setAction(StreamForegroundService.ACTION_START)
                                .putExtra(StreamForegroundService.EXTRA_MODE, mode)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                appContext.startForegroundService(intent)
                            } else {
                                appContext.startService(intent)
                            }
                            Log.i(TAG, "FGS start OK (mode=$mode)")
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "start FGS failed", e)
                            result.error("FGS_START_FAILED", e.message, null)
                        }
                    }

                    "stop" -> {
                        try {
                            val intent = Intent(appContext, StreamForegroundService::class.java)
                                .setAction(StreamForegroundService.ACTION_STOP)
                            appContext.startService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "stop FGS failed", e)
                            result.error("FGS_STOP_FAILED", e.message, null)
                        }
                    }

                    "bringToForeground" -> {
                        var anySuccess = false

                        // محاولة 1: startActivity مباشر
                        try {
                            val launchIntent = appContext.packageManager
                                .getLaunchIntentForPackage(appContext.packageName)
                            if (launchIntent != null) {
                                launchIntent.addFlags(
                                    Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                    Intent.FLAG_ACTIVITY_NO_ANIMATION
                                )
                                appContext.startActivity(launchIntent)
                                Log.i(TAG, "bringToForeground: direct startActivity OK")
                                anySuccess = true
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "direct startActivity failed: ${e.message}")
                        }

                        // محاولة 2: Full-Screen Intent notification
                        try {
                            showFullScreenWakeNotification(appContext)
                            Log.i(TAG, "bringToForeground: full-screen wake posted")
                            anySuccess = true
                        } catch (e: Exception) {
                            Log.w(TAG, "full-screen notification failed: ${e.message}")
                        }

                        if (anySuccess) result.success(true)
                        else result.error("BRING_FAILED", "كل محاولات الإحضار فشلت", null)
                    }

                    "requestBatteryOptimizationExemption" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                                if (!pm.isIgnoringBatteryOptimizations(appContext.packageName)) {
                                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                        .setData(Uri.parse("package:${appContext.packageName}"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    appContext.startActivity(intent)
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            Log.w(TAG, "requestBatteryOptimizationExemption failed", e)
                            result.success(false)
                        }
                    }

                    "hasOverlayPermission" -> {
                        val has = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            Settings.canDrawOverlays(appContext)
                        } else true
                        result.success(has)
                    }

                    "requestOverlayPermission" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:${appContext.packageName}")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                appContext.startActivity(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            Log.w(TAG, "requestOverlayPermission failed", e)
                            result.success(false)
                        }
                    }

                    "openAutoStartSettings" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${appContext.packageName}")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            appContext.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun showFullScreenWakeNotification(ctx: Context) {
        val launchIntent = ctx.packageManager
            .getLaunchIntentForPackage(ctx.packageName)
            ?: return
        launchIntent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_SINGLE_TOP or
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
            Intent.FLAG_ACTIVITY_NO_ANIMATION
        )

        val pending = PendingIntent.getActivity(
            ctx,
            1,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                WAKE_CHANNEL_ID,
                "Camera Wake (Boot)",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "فتح التطبيق عند وصول طلب مشاهدة بعد الإقلاع"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setShowBadge(false)
                enableVibration(false)
            }
            nm.createNotificationChannel(ch)
        }

        val notif = NotificationCompat.Builder(ctx, WAKE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("طلب مشاهدة جديد")
            .setContentText("جارٍ فتح الكاميرا...")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(pending, true)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setOngoing(false)
            .build()

        nm.notify(WAKE_NOTIFICATION_ID, notif)

        Handler(Looper.getMainLooper()).postDelayed({
            try { nm.cancel(WAKE_NOTIFICATION_ID) } catch (_: Exception) {}
        }, 5000L)
    }
}

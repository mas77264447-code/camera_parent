package com.example.camera_parent

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {

    companion object {
        private const val ADMIN_CHANNEL = "camera_parent/device_admin"
        private const val FOREGROUND_SERVICE_CHANNEL = "camera_parent/foreground_service"
        private const val SCREEN_CAPTURE_CHANNEL = "camera_parent/screen_capture"
        private const val BATTERY_OPTIMIZATION_CHANNEL = "camera_parent/battery_optimization"
        private const val MANAGE_STORAGE_CHANNEL = "camera_parent/manage_storage"
        private const val REQUEST_ADMIN_CODE = 4210

        private const val WAKE_CHANNEL_ID = "camera_wake_channel"
        private const val WAKE_NOTIFICATION_ID = 9999
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return (application as CameraParentApplication).ensureEngine()
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ═══════════════════════════════════════════════
        // Device Admin Channel
        // ═══════════════════════════════════════════════
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ADMIN_CHANNEL
        ).setMethodCallHandler { call, result ->

            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val adminComp = DeviceAdminReceiver.getComponentName(this)

            when (call.method) {
                "isAdminActive" -> result.success(DeviceAdminReceiver.isAdminActive(this))
                "isDeviceOwner" -> result.success(DeviceAdminReceiver.isDeviceOwner(this))

                "requestAdmin" -> {
                    if (DeviceAdminReceiver.isAdminActive(this)) {
                        result.success(true)
                    } else {
                        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                        intent.putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComp)
                        intent.putExtra(
                            DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                            "صلاحية مسؤول الجهاز مطلوبة لتشغيل الخدمة"
                        )
                        startActivityForResult(intent, REQUEST_ADMIN_CODE)
                        result.success("requested")
                    }
                }

                "lockScreen" -> {
                    if (DeviceAdminReceiver.isAdminActive(this)) {
                        dpm.lockNow(); result.success(true)
                    } else result.error("NOT_ADMIN", "Device Admin غير مفعل", null)
                }

                "setCameraDisabled" -> {
                    val disabled = call.argument<Boolean>("disabled") ?: true
                    if (DeviceAdminReceiver.isAdminActive(this)) {
                        dpm.setCameraDisabled(adminComp, disabled); result.success(true)
                    } else result.error("NOT_ADMIN", "Device Admin غير مفعل", null)
                }

                "removeAdmin" -> {
                    if (DeviceAdminReceiver.isAdminActive(this)) dpm.removeActiveAdmin(adminComp)
                    result.success(true)
                }

                "enableKioskMode" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.setLockTaskPackages(adminComp, arrayOf(packageName))
                        startLockTask(); result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }

                "disableKioskMode" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        stopLockTask(); result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }

                "disableWifiSettings" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, android.os.UserManager.DISALLOW_CONFIG_WIFI)
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }

                "disableInstallApps" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, android.os.UserManager.DISALLOW_INSTALL_APPS)
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }

                "disableFactoryReset" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, android.os.UserManager.DISALLOW_FACTORY_RESET)
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }

                "removeRestrictions" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.clearUserRestriction(adminComp, android.os.UserManager.DISALLOW_CONFIG_WIFI)
                        dpm.clearUserRestriction(adminComp, android.os.UserManager.DISALLOW_INSTALL_APPS)
                        dpm.clearUserRestriction(adminComp, android.os.UserManager.DISALLOW_FACTORY_RESET)
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }

                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════
        // Foreground Service Channel
        // ═══════════════════════════════════════════════
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "start" -> {
                    val intent = Intent(this, StreamForegroundService::class.java)
                        .setAction(StreamForegroundService.ACTION_START)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                    else startService(intent)
                    result.success(true)
                }

                "stop" -> {
                    startService(
                        Intent(this, StreamForegroundService::class.java)
                            .setAction(StreamForegroundService.ACTION_STOP)
                    )
                    result.success(true)
                }

                // ✅ إحضار التطبيق للمقدمة (يعمل حتى بدون صلاحية Overlay)
                "bringToForeground" -> {
                    try {
                        var anySuccess = false

                        // المحاولة 1: startActivity مباشر (يحتاج Overlay أو أن التطبيق
                        // لا يزال في المقدمة جزئياً)
                        try {
                            val direct = Intent(applicationContext, MainActivity::class.java).apply {
                                addFlags(
                                    Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                    Intent.FLAG_ACTIVITY_NO_ANIMATION
                                )
                            }
                            applicationContext.startActivity(direct)
                            Log.i("MainActivity", "bringToForeground: direct startActivity OK")
                            anySuccess = true
                        } catch (e: Exception) {
                            Log.w("MainActivity", "direct startActivity failed: ${e.message}")
                        }

                        // المحاولة 2: Full-Screen Intent (يعمل حتى بدون Overlay،
                        // وضروري على Android 14+)
                        try {
                            showFullScreenWakeNotification()
                            Log.i("MainActivity", "bringToForeground: full-screen wake posted")
                            anySuccess = true
                        } catch (e: Exception) {
                            Log.w("MainActivity", "full-screen notification failed: ${e.message}")
                        }

                        if (anySuccess) result.success(true)
                        else result.error("BRING_FAILED", "كل محاولات الإحضار فشلت", null)

                    } catch (e: Exception) {
                        Log.e("MainActivity", "bringToForeground failed", e)
                        result.error("BRING_FAILED", e.message, null)
                    }
                }

                // ✅ فحص صلاحية Overlay
                "hasOverlayPermission" -> {
                    val has = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                        Settings.canDrawOverlays(applicationContext)
                    result.success(has)
                }

                // ✅ طلب صلاحية Overlay (فتح شاشة الإعدادات)
                "requestOverlayPermission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OVERLAY_ERR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════
        // Battery Optimization Channel
        // ═══════════════════════════════════════════════
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BATTERY_OPTIMIZATION_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "requestBatteryOptimizationExemption" -> {
                    try {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                            !pm.isIgnoringBatteryOptimizations(packageName)
                        ) {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "hasOverlayPermission" -> {
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                            Settings.canDrawOverlays(this)
                    )
                }

                "requestOverlayPermission" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "openAutoStartSettings" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════
        // Screen Capture Channel
        // ═══════════════════════════════════════════════
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_CAPTURE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestScreenCapture" -> ScreenCaptureManager.request(this, result)
                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════
        // MANAGE_EXTERNAL_STORAGE Channel
        // ═══════════════════════════════════════════════
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MANAGE_STORAGE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                "openSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(intent)
                            result.success(true)
                        } else result.success(false)
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("ERR", e2.message, null)
                        }
                    }
                }

                "hasPermission" -> {
                    val has = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                        android.os.Environment.isExternalStorageManager() else true
                    result.success(has)
                }

                else -> result.notImplemented()
            }
        }
    }


    // ═══════════════════════════════════════════════
    // Full-Screen Intent Notification
    // ═══════════════════════════════════════════════
    private fun showFullScreenWakeNotification() {
        val fullScreenIntent = Intent(applicationContext, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_NO_ANIMATION
            )
        }

        val pending = PendingIntent.getActivity(
            this,
            0,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                WAKE_CHANNEL_ID,
                "Camera Wake",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "فتح التطبيق عند وصول طلب مشاهدة"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setShowBadge(false)
                enableVibration(false)
            }
            nm.createNotificationChannel(ch)
        }

        val notif = NotificationCompat.Builder(this, WAKE_CHANNEL_ID)
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


    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ScreenCaptureManager.REQUEST_CODE) {
            ScreenCaptureManager.onResult(resultCode, data)
        }
    }

    override fun onBackPressed() {
        try { super.onBackPressed() } catch (e: Exception) { finishAffinity() }
    }
}
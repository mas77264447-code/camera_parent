package com.example.camera_parent

import android.app.ActivityManager
import android.app.AlertDialog
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {

    companion object {

        private const val ADMIN_CHANNEL =
            "camera_parent/device_admin"

        private const val FOREGROUND_SERVICE_CHANNEL =
            "camera_parent/foreground_service"

        private const val SCREEN_CAPTURE_CHANNEL =
            "camera_parent/screen_capture"

        private const val BATTERY_OPTIMIZATION_CHANNEL =
            "camera_parent/battery_optimization"

        private const val MANAGE_STORAGE_CHANNEL =
            "camera_parent/manage_storage"

        private const val REQUEST_ADMIN_CODE = 4210
        private const val KIOSK_PREFS = "camera_parent_kiosk"
        private const val KIOSK_ENABLED = "enabled"

        // ✅ إصلاح: كان "8bak" (خطأ مطبعي) → 8951
        private const val OVERLAY_REQUEST_CODE = 8951
        private const val OVERLAY_PREFS = "camera_parent_overlay"
        private const val OVERLAY_ASKED = "asked"
    }


    override fun provideFlutterEngine(
        context: Context
    ): FlutterEngine {
        return (application as CameraParentApplication).flutterEngine
    }


    override fun shouldDestroyEngineWithHost(): Boolean {
        return false
    }


    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {

        // ===== قناة التحكم في صلاحيات الجهاز (Device Admin) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ADMIN_CHANNEL
        ).setMethodCallHandler { call, result ->

            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE)
                    as DevicePolicyManager
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
                        dpm.lockNow()
                        result.success(true)
                    } else {
                        result.error("NOT_ADMIN", "Device Admin غير مفعل", null)
                    }
                }
                "setCameraDisabled" -> {
                    val disabled = call.argument<Boolean>("disabled") ?: true
                    if (DeviceAdminReceiver.isAdminActive(this)) {
                        dpm.setCameraDisabled(adminComp, disabled)
                        result.success(true)
                    } else {
                        result.error("NOT_ADMIN", "Device Admin غير مفعل", null)
                    }
                }
                "removeAdmin" -> {
                    if (DeviceAdminReceiver.isAdminActive(this)) {
                        dpm.removeActiveAdmin(adminComp)
                    }
                    result.success(true)
                }
                "isKioskSupported" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP)
                }
                "getKioskStatus" -> {
                    val owner = DeviceAdminReceiver.isDeviceOwner(this)
                    val permitted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try { dpm.isLockTaskPermitted(packageName) } catch (_: Exception) { false }
                    } else owner
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
                    } else false
                    val enabled = getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                        .getBoolean(KIOSK_ENABLED, false)
                    val mode = when {
                        owner && permitted -> "device_owner"
                        active -> "screen_pinning"
                        enabled -> "screen_pinning_ready"
                        else -> "screen_pinning"
                    }
                    result.success(mapOf(
                        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP),
                        "deviceOwner" to owner,
                        "lockTaskPermitted" to permitted,
                        "active" to active,
                        "enabled" to enabled,
                        "mode" to mode,
                    ))
                }
                "isKioskActive" -> {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
                    } else false
                    result.success(active)
                }
                "isKioskEnabled" -> {
                    result.success(
                        getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                            .getBoolean(KIOSK_ENABLED, false)
                    )
                }
                "enableKioskMode" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
                        result.error("KIOSK_UNSUPPORTED", "هذا الإصدار لا يدعم Lock Task", null)
                        return@setMethodCallHandler
                    }
                    val owner = DeviceAdminReceiver.isDeviceOwner(this)
                    try {
                        if (owner) {
                            if (!configureKioskPolicy()) {
                                result.error("KIOSK_NOT_PERMITTED", "النظام لم يسمح بـ Lock Task", null)
                                return@setMethodCallHandler
                            }
                        }
                        getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                            .edit().putBoolean(KIOSK_ENABLED, true).apply()
                        startLockTask()
                        result.success(true)
                    } catch (e: SecurityException) {
                        result.error("KIOSK_SECURITY", e.message, null)
                    } catch (e: IllegalStateException) {
                        result.error("KIOSK_NOT_FOREGROUND", e.message, null)
                    } catch (e: Exception) {
                        result.error("KIOSK_ERROR", e.message, null)
                    }
                }
                "disableKioskMode" -> {
                    try {
                        getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                            .edit().putBoolean(KIOSK_ENABLED, false).apply()
                        stopLockTask()
                        if (DeviceAdminReceiver.isDeviceOwner(this)) {
                            clearKioskRestrictions()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("KIOSK_ERROR", e.message, null)
                    }
                }
                "disableWifiSettings" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, "no_config_wifi")
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }
                "disableInstallApps" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, "no_install_apps")
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }
                "disableFactoryReset" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, "no_factory_reset")
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }
                "removeRestrictions" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.clearUserRestriction(adminComp, "no_config_wifi")
                        dpm.clearUserRestriction(adminComp, "no_install_apps")
                        dpm.clearUserRestriction(adminComp, "no_factory_reset")
                        result.success(true)
                    } else result.error("NOT_OWNER", "يحتاج Device Owner", null)
                }
                else -> result.notImplemented()
            }
        }


        // ===== قناة خدمات الخلفية (Foreground Service) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, StreamForegroundService::class.java)
                        .setAction(StreamForegroundService.ACTION_START)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stop" -> {
                    startService(
                        Intent(this, StreamForegroundService::class.java)
                            .setAction(StreamForegroundService.ACTION_STOP)
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }


        // ===== قناة طلب استثناء البطارية =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BATTERY_OPTIMIZATION_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestBatteryOptimizationExemption" -> {
                    try {
                        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                            !powerManager.isIgnoringBatteryOptimizations(packageName)
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
                "openAutoStartSettings" -> {
                    try {
                        val intent = Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }


        // ===== قناة التقاط الشاشة (Screen Capture) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_CAPTURE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestScreenCapture" -> ScreenCaptureManager.request(this, result)
                else -> result.notImplemented()
            }
        }


        // ===== قناة "الوصول لجميع الملفات" (MANAGE_EXTERNAL_STORAGE) =====
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
                            val intent = Intent(
                                Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION
                            )
                            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("ERR", e2.message, null)
                        }
                    }
                }
                "hasPermission" -> {
                    val has = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        android.os.Environment.isExternalStorageManager()
                    } else true
                    result.success(has)
                }
                else -> result.notImplemented()
            }
        }


        // ===== قناة SYSTEM_ALERT_WINDOW (Overlay) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "camera_parent/overlay"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(canDrawOverlays())
                "requestPermission" -> {
                    requestOverlayPermission()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }


    // ===== هل لدينا صلاحية SYSTEM_ALERT_WINDOW؟ =====
    private fun canDrawOverlays(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }
    }


    // ===== فتح شاشة طلب السماح =====
    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !canDrawOverlays()) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                startActivityForResult(intent, OVERLAY_REQUEST_CODE)
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to request overlay permission", e)
            }
        }
    }


    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == ScreenCaptureManager.REQUEST_CODE) {
            ScreenCaptureManager.onResult(resultCode, data)
        }

        // ✅ بعد الرجوع من شاشة الإذن، سجّل أننا طلبناها
        if (requestCode == OVERLAY_REQUEST_CODE) {
            getSharedPreferences(OVERLAY_PREFS, MODE_PRIVATE)
                .edit().putBoolean(OVERLAY_ASKED, true).apply()
            Log.i("MainActivity", "Overlay permission requested, granted=${canDrawOverlays()}")
        }
    }


    override fun onResume() {
        super.onResume()
        ensureKioskMode()
        ensureOverlayPermissionOnce()
    }


    // ✅ اطلب إذن SYSTEM_ALERT_WINDOW مرة واحدة عند أول تشغيل
    private fun ensureOverlayPermissionOnce() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (canDrawOverlays()) return

        val asked = getSharedPreferences(OVERLAY_PREFS, MODE_PRIVATE)
            .getBoolean(OVERLAY_ASKED, false)

        if (!asked) {
            // استخدام android.app.AlertDialog (وليس androidx) لأن
            // FlutterActivity يمتد من Activity وليس AppCompatActivity
            try {
                AlertDialog.Builder(this)
                    .setTitle("صلاحية مطلوبة")
                    .setMessage(
                        "لكي تعمل الكاميرا في الخلفية بدون فتح التطبيق،\n" +
                        "نحتاج صلاحية \"العرض فوق التطبيقات الأخرى\".\n\n" +
                        "اضغط \"متابعة\" ثم فعّل الصلاحية."
                    )
                    .setCancelable(false)
                    .setPositiveButton("متابعة") { _, _ ->
                        requestOverlayPermission()
                    }
                    .show()
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to show overlay dialog", e)
                requestOverlayPermission()
            }
        }
    }


    override fun onPause() {
        super.onPause()
    }

    override fun onDestroy() {
        super.onDestroy()
    }


    private fun applyKioskRestrictions() {
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)
        val restrictions = mutableListOf(
            "no_control_apps", "no_uninstall_apps", "no_install_apps",
            "no_install_unknown_sources", "no_factory_reset", "no_safe_boot",
            "no_add_user", "no_user_switch", "no_modify_accounts",
            "no_debugging_features"
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            restrictions.add("no_usb_file_transfer")
        }
        if (Build.VERSION.SDK_INT >= 35) {
            restrictions.add("no_add_private_profile")
        }
        restrictions.forEach { restriction ->
            try { dpm.addUserRestriction(adminComp, restriction) }
            catch (_: SecurityException) {} catch (_: IllegalArgumentException) {}
        }
    }

    private fun configureKioskPolicy(): Boolean {
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return false
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)
        dpm.setLockTaskPackages(adminComp, arrayOf(packageName))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            dpm.setLockTaskFeatures(adminComp, DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
        }
        applyKioskRestrictions()
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || dpm.isLockTaskPermitted(packageName)
    }

    private fun clearKioskRestrictions() {
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)
        val restrictions = mutableListOf(
            "no_control_apps", "no_uninstall_apps", "no_install_apps",
            "no_install_unknown_sources", "no_factory_reset", "no_safe_boot",
            "no_add_user", "no_user_switch", "no_modify_accounts",
            "no_debugging_features"
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            restrictions.add("no_usb_file_transfer")
        }
        if (Build.VERSION.SDK_INT >= 35) {
            restrictions.add("no_add_private_profile")
        }
        restrictions.forEach { restriction ->
            try { dpm.clearUserRestriction(adminComp, restriction) } catch (_: Exception) {}
        }
    }

    private fun ensureKioskMode() {
        val requested = getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
            .getBoolean(KIOSK_ENABLED, false)
        if (!requested) return
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return
        if (!configureKioskPolicy()) return
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val locked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
        } else false
        if (!locked) {
            try { startLockTask() } catch (_: Exception) {}
        }
    }
}
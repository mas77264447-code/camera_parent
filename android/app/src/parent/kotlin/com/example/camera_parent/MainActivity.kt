package com.example.camera_parent

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity لتطبيق الوالد (Parent).
 *
 * القنوات المُسجّلة:
 *  - camera_parent/device_admin          إدارة الجهاز (اختياري)
 *  - camera_parent/screen_capture        التقاط الشاشة (اختياري)
 *  - camera_parent/battery_optimization  تحسين البطارية + الطبقة العائمة
 *  - camera_parent/manage_storage        إعدادات التخزين (WRITE/MANAGE)
 *
 * ملاحظات معمارية:
 *  - لا نستدعي super.configureFlutterEngine() لأن الإضافات مسجّلة مسبقاً
 *    في CameraParentApplication.ensureEngine() عبر GeneratedPluginRegistrant.
 *    إن ظهرت مشاكل مع إضافات تحتاج Activity context (url_launcher, image_picker,
 *    permission_handler ...)، فعّل السطر المُعلّق في configureFlutterEngine.
 *  - adminChannelRef حقل instance (وليس static) ليعكس دورة حياة النشاط.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "CameraParent"
        private const val ADMIN_CHANNEL = "camera_parent/device_admin"
        private const val SCREEN_CAPTURE_CHANNEL = "camera_parent/screen_capture"
        private const val BATTERY_OPTIMIZATION_CHANNEL = "camera_parent/battery_optimization"
        private const val MANAGE_STORAGE_CHANNEL = "camera_parent/manage_storage"
        private const val REQUEST_ADMIN_CODE = 4210
        // ⚠️ تأكد أن ScreenCaptureManager.REQUEST_CODE ≠ 4210،
        // وإلا سيُساء توجيه نتيجته في onActivityResult.
    }

    private var adminChannelRef: MethodChannel? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val app = application
        check(app is CameraParentApplication) {
            "AndroidManifest.xml يجب أن يعلن android:name=\".CameraParentApplication\" " +
                "داخل <application>. الـ Application الحالي: ${app::class.java.name}"
        }
        return app.flutterEngine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // FlutterActivity يحدّث intent داخلياً، لكن نؤكد صراحةً لتفادي أي التباس
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // super.configureFlutterEngine(flutterEngine) // ← فعّله إذا لزم (انظر التعليق أعلى الصنف)

        setupAdminChannel(flutterEngine)
        setupBatteryOptimizationChannel(flutterEngine)
        setupScreenCaptureChannel(flutterEngine)
        setupManageStorageChannel(flutterEngine)
    }

    // ═════════════════════════════ Device Admin ═════════════════════════════

    private fun setupAdminChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ADMIN_CHANNEL
        )
        adminChannelRef = channel
        channel.setMethodCallHandler { call, result ->
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val adminComp = DeviceAdminReceiver.getComponentName(this)

            when (call.method) {
                "isAdminActive" -> result.success(DeviceAdminReceiver.isAdminActive(this))
                "isDeviceOwner" -> result.success(DeviceAdminReceiver.isDeviceOwner(this))

                "requestAdmin" -> {
                    if (!canStartActivity()) {
                        result.error("NO_ACTIVITY", "MainActivity غير جاهزة", null)
                        return@setMethodCallHandler
                    }
                    if (DeviceAdminReceiver.isAdminActive(this)) {
                        result.success(true)
                    } else {
                        try {
                            val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                            intent.putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComp)
                            intent.putExtra(
                                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                "صلاحية مسؤول الجهاز مطلوبة لتشغيل الخدمة"
                            )
                            startActivityForResult(intent, REQUEST_ADMIN_CODE)
                            result.success("requested")
                        } catch (e: Exception) {
                            result.error("ADMIN_FAILED", e.message, null)
                        }
                    }
                }

                "lockScreen" -> {
                    if (!DeviceAdminReceiver.isAdminActive(this)) {
                        result.error("NOT_ADMIN", "Device Admin غير مفعل", null)
                        return@setMethodCallHandler
                    }
                    try {
                        dpm.lockNow()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_FAILED", e.message, null)
                    }
                }

                "setCameraDisabled" -> {
                    val disabled = call.argument<Boolean>("disabled") ?: true
                    if (!DeviceAdminReceiver.isAdminActive(this)) {
                        result.error("NOT_ADMIN", "Device Admin غير مفعل", null)
                        return@setMethodCallHandler
                    }
                    try {
                        dpm.setCameraDisabled(adminComp, disabled)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CAMERA_TOGGLE_FAILED", e.message, null)
                    }
                }

                "removeAdmin" -> {
                    try {
                        if (DeviceAdminReceiver.isAdminActive(this)) {
                            dpm.removeActiveAdmin(adminComp)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("REMOVE_FAILED", e.message, null)
                    }
                }

                "enableKioskMode" -> {
                    if (!DeviceAdminReceiver.isDeviceOwner(this)) {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                        return@setMethodCallHandler
                    }
                    try {
                        dpm.setLockTaskPackages(adminComp, arrayOf(packageName))
                        startLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("KIOSK_FAILED", e.message, null)
                    }
                }

                "disableKioskMode" -> {
                    if (!DeviceAdminReceiver.isDeviceOwner(this)) {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                        return@setMethodCallHandler
                    }
                    try {
                        stopLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("KIOSK_FAILED", e.message, null)
                    }
                }

                "disableWifiSettings",
                "disableInstallApps",
                "disableFactoryReset" -> {
                    val restriction = when (call.method) {
                        "disableWifiSettings" -> "no_config_wifi"
                        "disableInstallApps" -> "no_install_apps"
                        else -> "no_factory_reset"
                    }
                    if (!DeviceAdminReceiver.isDeviceOwner(this)) {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                        return@setMethodCallHandler
                    }
                    try {
                        dpm.addUserRestriction(adminComp, restriction)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("RESTRICTION_FAILED", e.message, null)
                    }
                }

                "removeRestrictions" -> {
                    if (!DeviceAdminReceiver.isDeviceOwner(this)) {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                        return@setMethodCallHandler
                    }
                    try {
                        dpm.clearUserRestriction(adminComp, "no_config_wifi")
                        dpm.clearUserRestriction(adminComp, "no_install_apps")
                        dpm.clearUserRestriction(adminComp, "no_factory_reset")
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("RESTRICTION_FAILED", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    // ═══════════════ Battery Optimization + Overlay ═══════════════

    private fun setupBatteryOptimizationChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BATTERY_OPTIMIZATION_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestBatteryOptimizationExemption" -> {
                    if (!canStartActivity()) {
                        result.error("NO_ACTIVITY", "MainActivity غير جاهزة", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                        Uri.parse("package:$packageName")
                                    )
                                )
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BATTERY_FAILED", e.message, null)
                    }
                }

                "openAutoStartSettings" -> {
                    if (!canStartActivity()) {
                        result.error("NO_ACTIVITY", "MainActivity غير جاهزة", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_FAILED", e.message, null)
                    }
                }

                "hasOverlayPermission" -> {
                    val has = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                        Settings.canDrawOverlays(this)
                    result.success(has)
                }

                "requestOverlayPermission" -> {
                    if (!canStartActivity()) {
                        result.error("NO_ACTIVITY", "MainActivity غير جاهزة", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OVERLAY_FAILED", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    // ═════════════════════════ Screen Capture ═════════════════════════

    private fun setupScreenCaptureChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_CAPTURE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestScreenCapture" -> {
                    if (!canStartActivity()) {
                        result.error("NO_ACTIVITY", "MainActivity غير جاهزة", null)
                        return@setMethodCallHandler
                    }
                    ScreenCaptureManager.request(this, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ═══════════════════════════ Manage Storage ═══════════════════════════

    private fun setupManageStorageChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MANAGE_STORAGE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openSettings" -> {
                    if (!canStartActivity()) {
                        result.error("NO_ACTIVITY", "MainActivity غير جاهزة", null)
                        return@setMethodCallHandler
                    }
                    openManageStorageSettings(result)
                }

                "hasPermission" -> result.success(hasStoragePermission())

                else -> result.notImplemented()
            }
        }
    }

    private fun openManageStorageSettings(result: MethodChannel.Result) {
        // 1) إعدادات الحزمة المخصصة (API 30+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName")
                    )
                )
                result.success(true)
                return
            } catch (_: Exception) {}
        }

        // 2) الإعداد العام لكل الملفات (API 30+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                result.success(true)
                return
            } catch (_: Exception) {}
        }

        // 3) تفاصيل التطبيق (كل الإصدارات كملاذ أخير)
        try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
            )
            result.success(true)
        } catch (e: Exception) {
            result.error(
                "SETTINGS_FAILED",
                "لا يمكن فتح إعدادات التخزين: ${e.message}",
                null
            )
        }
    }

    private fun hasStoragePermission(): Boolean {
        return when {
            // A11+ : MANAGE_EXTERNAL_STORAGE
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                Environment.isExternalStorageManager()

            // A10 وأقل : WRITE_EXTERNAL_STORAGE
            // ملاحظة: على A10 سيكون الوصول جزئياً فقط بسبب Scoped Storage
            else ->
                checkSelfPermission(
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED
        }
    }

    // ═══════════════════════════ Shared helpers ═══════════════════════════

    private fun canStartActivity(): Boolean = !isFinishing && !isDestroyed

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == ScreenCaptureManager.REQUEST_CODE) {
            ScreenCaptureManager.onResult(resultCode, data)
        } else if (requestCode == REQUEST_ADMIN_CODE) {
            val granted = resultCode == Activity.RESULT_OK
            try {
                adminChannelRef?.invokeMethod("adminRequestResult", granted)
            } catch (e: Exception) {
                Log.w(TAG, "adminRequestResult invoke failed: ${e.message}")
            }
        }
    }
}
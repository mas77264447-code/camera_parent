package com.example.camera_parent

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.app.ActivityManager
import android.util.Log
import android.provider.Settings
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

        private const val REQUEST_ADMIN_CODE = 4210
        private const val KIOSK_PREFS = "camera_parent_kiosk"
        private const val KIOSK_ENABLED = "enabled"
    }


    override fun provideFlutterEngine(
        context: Context
    ): FlutterEngine {

        return (application as CameraParentApplication)
            .flutterEngine
    }


    override fun shouldDestroyEngineWithHost(): Boolean {
        return false
    }


    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {

        // ملحوظة: ماننداش على super.configureFlutterEngine() هنا عن قصد.
        // الـ FlutterEngine ده Engine دائم (persistent) اتسجلت فيه كل
        // البلجنز مرة واحدة بس في CameraParentApplication.onCreate().
        // super.configureFlutterEngine() بينادي GeneratedPluginRegistrant
        // .registerWith() تاني، وده كان بيعمل detach/attach غير ضروري
        // لبلجنز الكاميرا وWebRTC في كل مرة الـ Activity تتفتح من جديد
        // (يعني كل مرة تفتح التطبيق تاني بعد قفله من الخلفية) - وده كان
        // بيقطع البث الشغال أو يسبب تجمد/كراش عند إعادة الفتح.

        // ===== قناة التحكم في صلاحيات الجهاز (Device Admin) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ADMIN_CHANNEL
        ).setMethodCallHandler { call, result ->

            val dpm =
                getSystemService(
                    Context.DEVICE_POLICY_SERVICE
                ) as DevicePolicyManager

            val adminComp =
                DeviceAdminReceiver
                    .getComponentName(this)

            when (call.method) {

                "isAdminActive" -> {

                    result.success(
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    )
                }

                "isDeviceOwner" -> {

                    result.success(
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    )
                }

                "requestAdmin" -> {

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        result.success(true)

                    } else {

                        val intent =
                            Intent(
                                DevicePolicyManager
                                .ACTION_ADD_DEVICE_ADMIN
                            )

                        intent.putExtra(
                            DevicePolicyManager
                            .EXTRA_DEVICE_ADMIN,
                            adminComp
                        )

                        intent.putExtra(
                            DevicePolicyManager
                            .EXTRA_ADD_EXPLANATION,
                            "صلاحية مسؤول الجهاز مطلوبة لتشغيل الخدمة"
                        )

                        startActivityForResult(
                            intent,
                            REQUEST_ADMIN_CODE
                        )

                        result.success("requested")
                    }
                }

                "lockScreen" -> {

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        dpm.lockNow()
                        result.success(true)

                    } else {

                        result.error(
                            "NOT_ADMIN",
                            "Device Admin غير مفعل",
                            null
                        )
                    }
                }

                "setCameraDisabled" -> {

                    val disabled =
                        call.argument<Boolean>(
                            "disabled"
                        ) ?: true

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        dpm.setCameraDisabled(
                            adminComp,
                            disabled
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_ADMIN",
                            "Device Admin غير مفعل",
                            null
                        )
                    }
                }

                "removeAdmin" -> {

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        dpm.removeActiveAdmin(
                            adminComp
                        )
                    }

                    result.success(true)
                }

                "isKioskSupported" -> {
                    result.success(
                        DeviceAdminReceiver.isDeviceOwner(this) &&
                            dpm.isLockTaskPermitted(packageName)
                    )
                }

                "isKioskActive" -> {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        am.lockTaskModeState == ActivityManager.LOCK_TASK_MODE_LOCKED
                    } else {
                        false
                    }
                    result.success(active)
                }

                "isKioskEnabled" -> {
                    result.success(getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                        .getBoolean(KIOSK_ENABLED, false))
                }

                "enableKioskMode" -> {
                    if (!DeviceAdminReceiver.isDeviceOwner(this)) {
                        result.error("NOT_OWNER", "يحتاج Device Owner لتفعيل Kiosk الحقيقي", null)
                    } else {
                        try {
                            if (!configureKioskPolicy()) {
                                result.error("KIOSK_NOT_PERMITTED", "النظام لم يسمح بقفل التطبيق", null)
                                return@setMethodCallHandler
                            }

                            getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                                .edit().putBoolean(KIOSK_ENABLED, true).apply()
                            startLockTask()
                            Log.i("KioskMode", "Kiosk enabled by user")
                            result.success(true)
                        } catch (e: SecurityException) {
                            result.error("KIOSK_SECURITY", e.message, null)
                        } catch (e: Exception) {
                            result.error("KIOSK_ERROR", e.message, null)
                        }
                    }
                }

                "disableKioskMode" -> {
                    if (!DeviceAdminReceiver.isDeviceOwner(this)) {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    } else {
                        try {
                            getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                                .edit().putBoolean(KIOSK_ENABLED, false).apply()
                            stopLockTask()
                            clearKioskRestrictions()
                            Log.i("KioskMode", "Kiosk disabled by user")
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("KIOSK_ERROR", e.message, null)
                        }
                    }
                }

                "disableWifiSettings" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.addUserRestriction(
                            adminComp,
                            "no_config_wifi"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "disableInstallApps" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.addUserRestriction(
                            adminComp,
                            "no_install_apps"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "disableFactoryReset" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.addUserRestriction(
                            adminComp,
                            "no_factory_reset"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "removeRestrictions" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.clearUserRestriction(
                            adminComp,
                            "no_config_wifi"
                        )

                        dpm.clearUserRestriction(
                            adminComp,
                            "no_install_apps"
                        )

                        dpm.clearUserRestriction(
                            adminComp,
                            "no_factory_reset"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ===== قناة خدمات الخلفية (Foreground Service) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->

            when(call.method) {

                "start" -> {

                    val intent =
                        Intent(
                            this,
                            StreamForegroundService::class.java
                        ).setAction(StreamForegroundService.ACTION_START)

                    if (
                        Build.VERSION.SDK_INT >=
                        Build.VERSION_CODES.O
                    ) {

                        startForegroundService(
                            intent
                        )

                    } else {

                        startService(
                            intent
                        )
                    }

                    result.success(true)
                }

                "stop" -> {

                    startService(
                        Intent(
                            this,
                            StreamForegroundService::class.java
                        ).setAction(StreamForegroundService.ACTION_STOP)
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

                        val powerManager =
                            getSystemService(
                                Context.POWER_SERVICE
                            ) as PowerManager

                        if (
                            Build.VERSION.SDK_INT >=
                            Build.VERSION_CODES.M &&
                            !powerManager
                                .isIgnoringBatteryOptimizations(
                                    packageName
                                )
                        ) {

                            val intent =
                                Intent(
                                    Settings
                                    .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse(
                                        "package:$packageName"
                                    )
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

                        val intent =
                            Intent(
                                Settings
                                .ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse(
                                    "package:$packageName"
                                )
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

            when(call.method) {

                "requestScreenCapture" -> {

                    ScreenCaptureManager.request(
                        this,
                        result
                    )
                }

                else -> result.notImplemented()
            }
        }
    }


    // ===== معالجة النتائج من الأنشطة =====
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {

        super.onActivityResult(
            requestCode,
            resultCode,
            data
        )

        if (
            requestCode ==
            ScreenCaptureManager.REQUEST_CODE
        ) {

            // بنستخدم الدالة الجاهزة في ScreenCaptureManager بدل الوصول
            // المباشر لخصائصه الـ private
            ScreenCaptureManager.onResult(
                resultCode,
                data
            )
        }
    }

    // ===== معالجة زر الرجوع =====
    override fun onBackPressed() {
        // التأكد من معالجة الرجوع بشكل صحيح
        try {
            super.onBackPressed()
        } catch (e: Exception) {
            // إذا حدثت مشكلة، نغلق التطبيق بشكل آمن
            finishAffinity()
        }
    }

    // ===== قيود Device Owner الخاصة بجهاز Kiosk =====
    // هذه القيود تمنع المستخدم العادي من إدارة التطبيقات أو الوصول
    // لمسارات إعدادات يمكن أن توقف التطبيق من واجهة Settings.
    // لا تتجاوز Force Stop نفسه؛ بل تمنع المسار الطبيعي للوصول إليه.
    private fun applyKioskRestrictions() {
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return

        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)

        // Use the platform restriction string values directly. This keeps the
        // child flavor compilable even when Flutter's compileSdk is older than
        // the API level that introduced one of these constants.
        val restrictions = mutableListOf(
            "no_control_apps",             // DISALLOW_APPS_CONTROL
            "no_uninstall_apps",           // DISALLOW_UNINSTALL_APPS
            "no_install_apps",             // DISALLOW_INSTALL_APPS
            "no_install_unknown_sources",  // DISALLOW_INSTALL_UNKNOWN_SOURCES
            "no_factory_reset",            // DISALLOW_FACTORY_RESET
            "no_safe_boot",                // DISALLOW_SAFE_BOOT
            "no_add_user",                 // DISALLOW_ADD_USER
            "no_user_switch",              // DISALLOW_USER_SWITCH
            "no_modify_accounts",          // DISALLOW_MODIFY_ACCOUNTS
            "no_debugging_features"        // DISALLOW_DEBUGGING_FEATURES
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            restrictions.add("no_usb_file_transfer") // DISALLOW_USB_FILE_TRANSFER
        }

        if (Build.VERSION.SDK_INT >= 35) {
            restrictions.add("no_add_private_profile") // Android 15+
        }

        restrictions.forEach { restriction ->
            try {
                dpm.addUserRestriction(adminComp, restriction)
            } catch (_: SecurityException) {
                // Some restrictions depend on OS/OEM policy.
            } catch (_: IllegalArgumentException) {
                // Ignore restrictions unsupported by this device.
            }
        }
    }

    private fun configureKioskPolicy(): Boolean {
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return false

        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)

        dpm.setLockTaskPackages(adminComp, arrayOf(packageName))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // لا Home / Recents / Notifications / System UI / Global Actions
            // أثناء Lock Task.
            dpm.setLockTaskFeatures(
                adminComp,
                DevicePolicyManager.LOCK_TASK_FEATURE_NONE
            )
        }

        applyKioskRestrictions()

        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            dpm.isLockTaskPermitted(packageName)
    }

    private fun clearKioskRestrictions() {
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return

        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)

        val restrictions = mutableListOf(
            "no_control_apps",
            "no_uninstall_apps",
            "no_install_apps",
            "no_install_unknown_sources",
            "no_factory_reset",
            "no_safe_boot",
            "no_add_user",
            "no_user_switch",
            "no_modify_accounts",
            "no_debugging_features"
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            restrictions.add("no_usb_file_transfer")
        }
        if (Build.VERSION.SDK_INT >= 35) {
            restrictions.add("no_add_private_profile")
        }

        restrictions.forEach { restriction ->
            try {
                dpm.clearUserRestriction(adminComp, restriction)
            } catch (_: Exception) {
                // Ignore unsupported restrictions.
            }
        }
    }

    // ===== إعادة الدخول إلى Kiosk عند عودة Activity =====
    private fun ensureKioskMode() {
        val requested = getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
            .getBoolean(KIOSK_ENABLED, false)
        if (!requested) return
        if (!DeviceAdminReceiver.isDeviceOwner(this)) return

        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        if (!configureKioskPolicy()) return

        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val locked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.lockTaskModeState == ActivityManager.LOCK_TASK_MODE_LOCKED
        } else {
            false
        }

        if (!locked) {
            try {
                startLockTask()
            } catch (_: Exception) {
                // سيحاول النظام مرة أخرى عند onResume التالية.
            }
        }
    }

    // ===== معالجة دورة حياة الـ Activity =====
    override fun onResume() {
        super.onResume()
        ensureKioskMode()
    }

    override fun onPause() {
        super.onPause()
        // تحرير الموارد
    }

    override fun onDestroy() {
        super.onDestroy()
        // تنظيف الموارد النهائي
    }
}

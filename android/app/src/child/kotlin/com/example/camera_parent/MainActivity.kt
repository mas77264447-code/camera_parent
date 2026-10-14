package com.example.camera_parent

import android.app.Activity
import android.app.ActivityManager
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

        private const val ADMIN_CHANNEL = "camera_parent/device_admin"
        private const val FOREGROUND_SERVICE_CHANNEL = "camera_parent/foreground_service"
        private const val SCREEN_CAPTURE_CHANNEL = "camera_parent/screen_capture"
        private const val BATTERY_OPTIMIZATION_CHANNEL = "camera_parent/battery_optimization"

        private const val REQUEST_ADMIN_CODE = 4210

        private const val KIOSK_PREFS = "camera_parent_kiosk"
        private const val KIOSK_ENABLED = "enabled"

        // ✅ مرجع لإرسال نتيجة موافقة/رفض الأدمن بعد onActivityResult
        private var adminChannelRef: MethodChannel? = null
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return (application as CameraParentApplication).flutterEngine
    }


    override fun shouldDestroyEngineWithHost(): Boolean = false


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {

        // ملاحظة مهمة: لا نستدعي super.configureFlutterEngine() عن قصد.
        // الـ Engine دائم (persistent) ومُسجَّل فيه البلجنز مرة واحدة في
        // CameraParentApplication.onCreate(). استدعاء super يؤدي إلى
        // GeneratedPluginRegistrant.registerWith() مرة ثانية، وهذا يسبب
        // detach/attach غير ضروري لبلجنز الكاميرا/WebRTC ويقطع البث
        // كلما أُعيد فتح الـ Activity بعد إغلاق التطبيق من الخلفية.

        // ═══════════════════════════════════════════════════════
        // 1) Device Admin + Kiosk Channel
        // ═══════════════════════════════════════════════════════
        val adminChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ADMIN_CHANNEL
        )
        adminChannelRef = adminChannel
        adminChannel.setMethodCallHandler { call, result ->

            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val adminComp = DeviceAdminReceiver.getComponentName(this)

            when (call.method) {

                "isAdminActive" -> result.success(
                    DeviceAdminReceiver.isAdminActive(this)
                )

                "isDeviceOwner" -> result.success(
                    DeviceAdminReceiver.isDeviceOwner(this)
                )

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

                    result.success(
                        mapOf(
                            "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP),
                            "deviceOwner" to owner,
                            "lockTaskPermitted" to permitted,
                            "active" to active,
                            "enabled" to enabled,
                            "mode" to mode,
                        )
                    )
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
                        result.error(
                            "KIOSK_UNSUPPORTED",
                            "هذا الإصدار من Android لا يدعم Lock Task",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    val owner = DeviceAdminReceiver.isDeviceOwner(this)

                    try {
                        if (owner) {
                            // المسار الكامل: Device Owner + Lock Task مُدار
                            if (!configureKioskPolicy()) {
                                result.error(
                                    "KIOSK_NOT_PERMITTED",
                                    "التطبيق أصبح Device Owner لكن النظام لم يسمح بـ Lock Task",
                                    null
                                )
                                return@setMethodCallHandler
                            }
                        } else {
                            // المسار البديل: Screen Pinning (رسمي من Android)
                            Log.i(
                                "KioskMode",
                                "Device Owner غير موجود؛ استخدام Screen Pinning كبديل"
                            )
                        }

                        getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                            .edit()
                            .putBoolean(KIOSK_ENABLED, true)
                            .apply()

                        // يجب أن يكون الـ Activity في المقدمة (وهذا صحيح لأن
                        // النداء يأتي من MethodChannel أثناء استخدام الشاشة)
                        startLockTask()

                        Log.i(
                            "KioskMode",
                            if (owner) "Managed Lock Task enabled"
                            else "Screen Pinning requested"
                        )
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
                            .edit()
                            .putBoolean(KIOSK_ENABLED, false)
                            .apply()

                        // يعمل أيضًا مع Screen Pinning. لا نحتاج Device Owner
                        // لإيقاف Lock Task الذي بدأه التطبيق نفسه.
                        stopLockTask()

                        if (DeviceAdminReceiver.isDeviceOwner(this)) {
                            clearKioskRestrictions()
                        }

                        Log.i("KioskMode", "Kiosk/Screen Pinning disabled by user")
                        result.success(true)

                    } catch (e: Exception) {
                        result.error("KIOSK_ERROR", e.message, null)
                    }
                }

                "disableWifiSettings" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, "no_config_wifi")
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "disableInstallApps" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, "no_install_apps")
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "disableFactoryReset" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(adminComp, "no_factory_reset")
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "removeRestrictions" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.clearUserRestriction(adminComp, "no_config_wifi")
                        dpm.clearUserRestriction(adminComp, "no_install_apps")
                        dpm.clearUserRestriction(adminComp, "no_factory_reset")
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════════════
        // 2) Foreground Service Channel
        // ═══════════════════════════════════════════════════════
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "start" -> {
                    // ✅ إصلاح: قراءة mode من Dart (camera/screen/files)
                    val mode = call.argument<String>("mode")
                        ?: StreamForegroundService.MODE_CAMERA

                    val intent = Intent(this, StreamForegroundService::class.java)
                        .setAction(StreamForegroundService.ACTION_START)
                        .putExtra(StreamForegroundService.EXTRA_MODE, mode)

                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "startForegroundService failed mode=$mode", e)
                        result.error("FGS_START", e.message, null)
                    }
                }

                "stop" -> {
                    try {
                        startService(
                            Intent(this, StreamForegroundService::class.java)
                                .setAction(StreamForegroundService.ACTION_STOP)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FGS_STOP", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════════════
        // 3) Battery Optimization Channel
        // ═══════════════════════════════════════════════════════
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
                            startActivity(
                                Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        }
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


        // ═══════════════════════════════════════════════════════
        // 4) Screen Capture Channel
        // ═══════════════════════════════════════════════════════
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_CAPTURE_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "requestScreenCapture" -> {
                    ScreenCaptureManager.request(this, result)
                }
                else -> result.notImplemented()
            }
        }
    }


    // ═══════════════════════════════════════════════════════════
    // onActivityResult — معالجة admin + screen capture
    // ═══════════════════════════════════════════════════════════
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == ScreenCaptureManager.REQUEST_CODE) {
            ScreenCaptureManager.onResult(resultCode, data)
        } else if (requestCode == REQUEST_ADMIN_CODE) {
            // ✅ إرسال نتيجة موافقة/رفض الأدمن إلى Flutter
            val granted = resultCode == Activity.RESULT_OK
            try {
                adminChannelRef?.invokeMethod("adminRequestResult", granted)
            } catch (_: Exception) {}
        }
    }


    // ═══════════════════════════════════════════════════════════
    // Kiosk helpers (private — تُستدعى من enable/disableKioskMode)
    // ═══════════════════════════════════════════════════════════
    private fun configureKioskPolicy(): Boolean {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)
        return try {
            dpm.setLockTaskPackages(adminComp, arrayOf(packageName))
            true
        } catch (e: Exception) {
            Log.w("KioskMode", "setLockTaskPackages failed", e)
            false
        }
    }

    private fun clearKioskRestrictions() {
        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val adminComp = DeviceAdminReceiver.getComponentName(this)
        try {
            dpm.setLockTaskPackages(adminComp, emptyArray())
        } catch (e: Exception) {
            Log.w("KioskMode", "clearLockTaskPackages failed", e)
        }
    }
}
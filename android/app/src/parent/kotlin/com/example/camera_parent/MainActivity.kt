package com.example.camera_parent

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {

    companion object {
        private const val ADMIN_CHANNEL = "camera_parent/device_admin"
        private const val SCREEN_CAPTURE_CHANNEL = "camera_parent/screen_capture"
        private const val BATTERY_OPTIMIZATION_CHANNEL = "camera_parent/battery_optimization"
        private const val MANAGE_STORAGE_CHANNEL = "camera_parent/manage_storage"
        private const val REQUEST_ADMIN_CODE = 4210

        private var adminChannelRef: MethodChannel? = null
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return (application as CameraParentApplication).flutterEngine
    }


    override fun shouldDestroyEngineWithHost(): Boolean = false


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {

        // ملاحظة: لا نستدعي super.configureFlutterEngine() عن قصد.
        // الـ Engine دائم ومُسجَّل فيه البلجنز مرة واحدة في
        // CameraParentApplication.onCreate().


        // ═══════════════════════════════════════════════
        // 1) Device Admin Channel
        // ═══════════════════════════════════════════════
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

                "enableKioskMode" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.setLockTaskPackages(adminComp, arrayOf(packageName))
                        startLockTask(); result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "disableKioskMode" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        stopLockTask(); result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "disableWifiSettings" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(
                            adminComp,
                            android.os.UserManager.DISALLOW_CONFIG_WIFI
                        )
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "disableInstallApps" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(
                            adminComp,
                            android.os.UserManager.DISALLOW_INSTALL_APPS
                        )
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "disableFactoryReset" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.addUserRestriction(
                            adminComp,
                            android.os.UserManager.DISALLOW_FACTORY_RESET
                        )
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                "removeRestrictions" -> {
                    if (DeviceAdminReceiver.isDeviceOwner(this)) {
                        dpm.clearUserRestriction(
                            adminComp,
                            android.os.UserManager.DISALLOW_CONFIG_WIFI
                        )
                        dpm.clearUserRestriction(
                            adminComp,
                            android.os.UserManager.DISALLOW_INSTALL_APPS
                        )
                        dpm.clearUserRestriction(
                            adminComp,
                            android.os.UserManager.DISALLOW_FACTORY_RESET
                        )
                        result.success(true)
                    } else {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════
        // 2) Battery Optimization + Overlay Permissions
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

                "hasOverlayPermission" -> {
                    val has = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                        Settings.canDrawOverlays(this)
                    result.success(has)
                }

                "requestOverlayPermission" -> {
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
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ═══════════════════════════════════════════════
        // 3) Screen Capture Channel
        //    (Parent قد يحتاج عرض/طلب MediaProjection من Child)
        // ═══════════════════════════════════════════════
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


        // ═══════════════════════════════════════════════
        // 4) MANAGE_EXTERNAL_STORAGE Channel ✅ خاص بالوالد
        //    يُستخدم لحفظ الملفات المُنزَّلة من جهاز الطفل
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
                        } else {
                            // A10 وأقل: افتح شاشة صلاحيات التطبيق
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                ).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
                            )
                            result.success(true)
                        }
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
                    } else {
                        checkSelfPermission(
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    }
                    result.success(has)
                }

                else -> result.notImplemented()
            }
        }
    }


    // ═══════════════════════════════════════════════
    // onActivityResult
    // ═══════════════════════════════════════════════
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == ScreenCaptureManager.REQUEST_CODE) {
            ScreenCaptureManager.onResult(resultCode, data)
        } else if (requestCode == REQUEST_ADMIN_CODE) {
            val granted = resultCode == Activity.RESULT_OK
            try {
                adminChannelRef?.invokeMethod("adminRequestResult", granted)
            } catch (_: Exception) {}
        }
    }
}
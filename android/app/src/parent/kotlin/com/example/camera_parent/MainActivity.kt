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

        private const val ADMIN_CHANNEL =
            "camera_parent/device_admin"

        private const val FOREGROUND_SERVICE_CHANNEL =
            "camera_parent/foreground_service"

        private const val SCREEN_CAPTURE_CHANNEL =
            "camera_parent/screen_capture"

        private const val BATTERY_OPTIMIZATION_CHANNEL =
            "camera_parent/battery_optimization"

        private const val REQUEST_ADMIN_CODE = 4210
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

                "enableKioskMode" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.setLockTaskPackages(
                            adminComp,
                            arrayOf(packageName)
                        )

                        startLockTask()

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "disableKioskMode" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        stopLockTask()

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "disableWifiSettings" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.addUserRestriction(
                            adminComp,
                            android.os.UserManager
                                .DISALLOW_CONFIG_WIFI
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
                            android.os.UserManager
                                .DISALLOW_INSTALL_APPS
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
                            android.os.UserManager
                                .DISALLOW_FACTORY_RESET
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
                            android.os.UserManager
                                .DISALLOW_CONFIG_WIFI
                        )

                        dpm.clearUserRestriction(
                            adminComp,
                            android.os.UserManager
                                .DISALLOW_INSTALL_APPS
                        )

                        dpm.clearUserRestriction(
                            adminComp,
                            android.os.UserManager
                                .DISALLOW_FACTORY_RESET
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
            // المباشر لخصائصه الـ private - ده هو اللي كان بيسبب خطأ
            // "Cannot access ... it is private in ScreenCaptureManager"
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

    // ===== معالجة دورة حياة الـ Activity =====
    override fun onResume() {
        super.onResume()
        // التأكد من أن الواجهة نشطة
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

package com.example.camera_parent

import android.app.Activity
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
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "CameraParent"
        private const val ADMIN_CHANNEL = "camera_parent/device_admin"
        private const val SCREEN_CAPTURE_CHANNEL = "camera_parent/screen_capture"
        private const val BATTERY_OPTIMIZATION_CHANNEL = "camera_parent/battery_optimization"
        private const val REQUEST_ADMIN_CODE = 4210
        private const val WARMUP_TIMEOUT_MS = 8000L
        // ⚠️ تأكد أن ScreenCaptureManager.REQUEST_CODE ≠ 4210
    }

    // ═══ حقل instance (وليس static) — يرتبط بدورة حياة النشاط ═══
    private var adminChannelRef: MethodChannel? = null

    // ═══ Warmup (بعد الإقلاع) ═══
    private val warmupHandler = Handler(Looper.getMainLooper())
    private var warmupRunnable: Runnable? = null
    private var warmupActive = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)

        // ✅ منع تكرار warmup عند إعادة إنشاء النشاط (تدوير/تغيير حجم/recents)
        if (savedInstanceState == null &&
            intent?.getBooleanExtra("from_boot", false) == true
        ) {
            startWarmup()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        // ✅ أي فتح من المستخدم (لا من الإقلاع) يُلغي وضع warmup
        //    وإلا كان finishAndRemoveTask سيقتل التطبيق على المستخدم بعد 8 ثوانٍ.
        if (intent.getBooleanExtra("from_boot", false) != true) {
            cancelWarmup()
        }
    }

    override fun onDestroy() {
        cancelWarmup()
        super.onDestroy()
    }

    private fun startWarmup() {
        Log.i(TAG, "MainActivity: warmup start (${WARMUP_TIMEOUT_MS}ms)")

        try {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            )
        } catch (_: Exception) {}

        warmupActive = true
        warmupRunnable = Runnable {
            if (!warmupActive) return@Runnable
            try {
                finishAndRemoveTask()
                Log.i(TAG, "MainActivity: warmup auto-closed")
            } catch (_: Exception) {
                finish()
            }
        }.also { warmupHandler.postDelayed(it, WARMUP_TIMEOUT_MS) }
    }

    private fun cancelWarmup() {
        if (!warmupActive) return
        warmupActive = false
        warmupRunnable?.let { warmupHandler.removeCallbacks(it) }
        warmupRunnable = null
        try {
            window.clearFlags(
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            )
        } catch (_: Exception) {}
        Log.i(TAG, "MainActivity: warmup cancelled")
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val app = application
        check(app is CameraParentApplication) {
            "AndroidManifest.xml يجب أن يعلن android:name=\".CameraParentApplication\" " +
                "داخل <application>. الـ Application الحالي: ${app::class.java.name}"
        }
        return app.flutterEngine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // لا نستدعي super.configureFlutterEngine() لأن الإضافات مسجّلة مسبقاً
        // في CameraParentApplication.ensureEngine() عبر GeneratedPluginRegistrant.

        setupAdminChannel(flutterEngine)
        setupBatteryOptimizationChannel(flutterEngine)
        setupScreenCaptureChannel(flutterEngine)
    }

    // ═══════════════════════════ Admin ═══════════════════════════

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
                        dpm.lockNow(); result.success(true)
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
                        dpm.setCameraDisabled(adminComp, disabled); result.success(true)
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
                        startLockTask(); result.success(true)
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
                        stopLockTask(); result.success(true)
                    } catch (e: Exception) {
                        result.error("KIOSK_FAILED", e.message, null)
                    }
                }

                "disableWifiSettings",
                "disableInstallApps",
                "disableFactoryReset" -> {
                    if (!DeviceAdminReceiver.isDeviceOwner(this)) {
                        result.error("NOT_OWNER", "يحتاج Device Owner", null)
                        return@setMethodCallHandler
                    }
                    val restriction = when (call.method) {
                        "disableWifiSettings" -> "no_config_wifi"
                        "disableInstallApps" -> "no_install_apps"
                        else -> "no_factory_reset"
                    }
                    try {
                        dpm.addUserRestriction(adminComp, restriction); result.success(true)
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

    // ═══════════════════════ Helpers ═══════════════════════

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
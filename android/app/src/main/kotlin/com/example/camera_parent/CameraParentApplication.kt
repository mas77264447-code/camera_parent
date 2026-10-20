package com.example.camera_parent

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class CameraParentApplication : Application() {

    companion object {
        const val ENGINE_ID = "camera_parent_persistent_engine"

        @Volatile
        private var appContext: Context? = null

        fun appContext(): Context? = appContext
    }

    lateinit var flutterEngine: FlutterEngine
        private set

    override fun onCreate() {
        super.onCreate()
        appContext = applicationContext
        BootLog.init(this)
        BootLog.w("process start pid=${android.os.Process.myPid()} sdk=${android.os.Build.VERSION.SDK_INT} model=${android.os.Build.MANUFACTURER}/${android.os.Build.MODEL}")
        logPreviousExitReasons()
        installCrashLogger()
        ensureEngine()
    }

    /**
     * يكتب أي استثناء غير مُلتقط (JVM-level) في ملف داخل Downloads العامة،
     * قابل للقراءة من Termux بدون adb. أداة تشخيص مؤقتة لتتبع سبب انهيار
     * العملية عند قبول مشاهد جديد (ws close code=1006).
     */
    private fun installCrashLogger() {
        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                BootLog.w(
                    "CRASH [kotlin/${thread.name}]\n" +
                        android.util.Log.getStackTraceString(throwable)
                )
            } catch (_: Throwable) {
            }
            defaultHandler?.uncaughtException(thread, throwable)
        }
    }

    /** سبب موت العمليات السابقة (Android 11+): crash / native crash / low memory / kill ... */
    private fun logPreviousExitReasons() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) return
        try {
            val am = getSystemService(android.app.ActivityManager::class.java) ?: return
            val list = am.getHistoricalProcessExitReasons(packageName, 0, 6)
            for (r in list) {
                BootLog.w(
                    "PREV-EXIT time=${r.timestamp} reason=${r.reason}(${exitReasonName(r.reason)}) " +
                        "status=${r.status} importance=${r.importance} desc=${r.description}"
                )
            }
            if (list.isEmpty()) BootLog.w("PREV-EXIT none recorded")
        } catch (e: Throwable) {
            BootLog.w("PREV-EXIT failed: $e")
        }
    }

    private fun exitReasonName(r: Int): String = when (r) {
        1 -> "EXIT_SELF"
        2 -> "SIGNALED"
        3 -> "LOW_MEMORY"
        4 -> "CRASH"
        5 -> "CRASH_NATIVE"
        6 -> "ANR"
        7 -> "INITIALIZATION_FAILURE"
        8 -> "PERMISSION_CHANGE"
        9 -> "EXCESSIVE_RESOURCE_USAGE"
        10 -> "USER_REQUESTED"
        11 -> "USER_STOPPED"
        12 -> "DEPENDENCY_DIED"
        13 -> "OTHER"
        14 -> "FREEZER"
        15 -> "PACKAGE_STATE_CHANGE"
        16 -> "PACKAGE_UPDATED"
        else -> "UNKNOWN"
    }

    @Synchronized
    fun ensureEngine(): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let {
            flutterEngine = it
            return it
        }

        val engine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(engine)

        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )

        FileAccessPlugin.register(
            applicationContext,
            MethodChannel(engine.dartExecutor.binaryMessenger, "camera_parent/file_access")
        )

        MethodChannel(engine.dartExecutor.binaryMessenger, "camera_parent/diag_log")
            .setMethodCallHandler { call, result ->
                if (call.method == "log") {
                    BootLog.w(call.arguments?.toString() ?: "")
                    result.success(true)
                } else result.notImplemented()
            }

        ConnectivityChannel.setup(engine)
        NetworkConnectivityListener(applicationContext) { online ->
            ConnectivityChannel.sendNetworkState(online)
        }.start()

        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        flutterEngine = engine
        return engine
    }
}

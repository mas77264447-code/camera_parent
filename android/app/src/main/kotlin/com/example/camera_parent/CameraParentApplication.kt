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
                val dir = android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS
                )
                val file = java.io.File(dir, "camera_parent_crash.log")
                file.appendText(
                    "\n=== ${java.util.Date()} [native/${thread.name}] ===\n" +
                        android.util.Log.getStackTraceString(throwable) + "\n"
                )
            } catch (_: Exception) {
                // تجاهل: لا نريد أن يفشل تسجيل الكرش بسبب كرش آخر
            }
            defaultHandler?.uncaughtException(thread, throwable)
        }
    }

    @Synchronized
    private fun readExitInfo(): List<String> {
        val out = ArrayList<String>()
        out.add("pid=${android.os.Process.myPid()} sdk=${android.os.Build.VERSION.SDK_INT}")
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            try {
                out.addAll(readExitInfoApi30())
            } catch (e: Exception) {
                out.add("exitInfo error: ${e.message}")
            }
        }
        return out
    }

    @android.annotation.TargetApi(30)
    private fun readExitInfoApi30(): List<String> {
        val out = ArrayList<String>()
        val am = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
        for (i in am.getHistoricalProcessExitReasons(packageName, 0, 5)) {
            val reason = when (i.reason) {
                0 -> "UNKNOWN"
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
                else -> "REASON_${i.reason}"
            }
            out.add(
                "exit t=${fmt.format(java.util.Date(i.timestamp))} proc=${i.processName} " +
                    "reason=$reason status=${i.status} importance=${i.importance} desc=${i.description}"
            )
        }
        return out
    }

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

        // تشخيص: أسباب موت العملية السابقة (API 30+) تُرسَل من Dart إلى السيرفر
        MethodChannel(engine.dartExecutor.binaryMessenger, "camera_parent/diag")
            .setMethodCallHandler { call, result ->
                if (call.method == "exitInfo") {
                    result.success(readExitInfo())
                } else {
                    result.notImplemented()
                }
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

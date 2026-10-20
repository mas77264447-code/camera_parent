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

        ConnectivityChannel.setup(engine)
        NetworkConnectivityListener(applicationContext) { online ->
            ConnectivityChannel.sendNetworkState(online)
        }.start()

        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        flutterEngine = engine
        return engine
    }
}

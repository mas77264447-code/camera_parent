package com.example.camera_parent

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.util.concurrent.atomic.AtomicInteger
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

        private val startedActivities = AtomicInteger(0)

        /** true فقط عندما توجد Activity ظاهرة فعلاً (started). الـ Engine يبقى حياً بدونها. */
        fun isUiVisible(): Boolean = startedActivities.get() > 0

        @Volatile
        private var topActivityRef: java.lang.ref.WeakReference<Activity>? = null

        /** يُرجع التطبيق للخلفية (شاشة مخفية = paused) دون إغلاقه. */
        fun sendToBack(): Boolean {
            val a = topActivityRef?.get() ?: return false
            return try { a.moveTaskToBack(true) } catch (_: Exception) { false }
        }
    }

    lateinit var flutterEngine: FlutterEngine
        private set

    override fun onCreate() {
        super.onCreate()
        appContext = applicationContext
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                startedActivities.incrementAndGet()
                topActivityRef = java.lang.ref.WeakReference(activity)
            }
            override fun onActivityStopped(activity: Activity) {
                if (startedActivities.decrementAndGet() < 0) startedActivities.set(0)
            }
            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
        ensureEngine()
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

        // ✅ تسجيل ForegroundServiceChannel (start/stop/bringToForeground/...)
        ForegroundServiceChannel.setup(engine, applicationContext)

        ConnectivityChannel.setup(engine)
        NetworkConnectivityListener(applicationContext) { online ->
            ConnectivityChannel.sendNetworkState(online)
        }.start()

        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        flutterEngine = engine
        return engine
    }
}

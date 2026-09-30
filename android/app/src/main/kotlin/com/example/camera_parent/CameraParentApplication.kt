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

        ConnectivityChannel.setup(engine)
        NetworkConnectivityListener(applicationContext) { online ->
            ConnectivityChannel.sendNetworkState(online)
        }.start()

        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        flutterEngine = engine
        return engine
    }
}

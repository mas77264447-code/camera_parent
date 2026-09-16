package com.example.camera_parent

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

class CameraParentApplication : Application() {

    companion object {
        const val ENGINE_ID = "camera_parent_persistent_engine"
    }

    lateinit var flutterEngine: FlutterEngine
        private set

    private var networkMonitor: NetworkMonitor? = null


    object AppHolder {
        var engine: FlutterEngine? = null
        var context: Context? = null
    }


    override fun onCreate() {
        super.onCreate()

        // حفظ Context لاستخدامه من ForegroundService
        AppHolder.context = applicationContext


        flutterEngine = FlutterEngine(this)

        GeneratedPluginRegistrant.registerWith(flutterEngine)


        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )


        AppHolder.engine = flutterEngine

        // The engine is persistent, so register the native connectivity bridge
        // once and keep the network monitor alive for the lifetime of the app.
        ConnectivityChannel.setup(flutterEngine)
        networkMonitor = NetworkMonitor(applicationContext).also { it.start() }


        FlutterEngineCache
            .getInstance()
            .put(
                ENGINE_ID,
                flutterEngine
            )
    }
}
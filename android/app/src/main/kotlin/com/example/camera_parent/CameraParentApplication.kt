package com.example.camera_parent

import android.app.Application
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

    object AppHolder {
        var engine: FlutterEngine? = null
    }

    override fun onCreate() {
        super.onCreate()

        flutterEngine = FlutterEngine(this)

        GeneratedPluginRegistrant.registerWith(flutterEngine)

        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )

        AppHolder.engine = flutterEngine

        FlutterEngineCache
            .getInstance()
            .put(
                ENGINE_ID,
                flutterEngine
            )
    }
}
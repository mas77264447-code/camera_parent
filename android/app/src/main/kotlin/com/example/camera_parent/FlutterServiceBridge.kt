package com.example.camera_parent

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

object FlutterServiceBridge {

    private const val CHANNEL = "camera_parent/service"


    fun startAgent() {

        val engine = getOrCreateEngine()

        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CHANNEL
        ).invokeMethod(
            "startAgent",
            null
        )
    }


    private fun getOrCreateEngine(): FlutterEngine {

        // استخدام FlutterEngine الموجود
        CameraParentApplication.AppHolder.engine?.let {
            return it
        }


        // إنشاء Engine جديد إذا تم قتله بعد ضغط X
        val context =
            CameraParentApplication.AppHolder.context
                ?: throw IllegalStateException(
                    "Application context missing"
                )


        val engine = FlutterEngine(context)


        GeneratedPluginRegistrant.registerWith(engine)


        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )


        CameraParentApplication.AppHolder.engine = engine


        FlutterEngineCache
            .getInstance()
            .put(
                CameraParentApplication.ENGINE_ID,
                engine
            )


        return engine
    }
}
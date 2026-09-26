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
        private const val FILE_ACCESS_CHANNEL = "camera_parent/file_access"
    }

    lateinit var flutterEngine: FlutterEngine
        private set


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


        // ✅✅✅ إصلاح جذري: تسجيل FileAccessPlugin هنا بدلاً من MainActivity
        // السبب: عندما يُعاد تشغيل التطبيق من الخدمة (بدون Activity)،
        // لا يتم استدعاء configureFlutterEngine في MainActivity، فتفشل
        // جميع قنوات MethodChannel بـ MissingPluginException.
        // التسجيل في Application يضمن أن القناة متاحة دائماً.
        try {
            FileAccessPlugin.register(
                applicationContext,
                MethodChannel(
                    flutterEngine.dartExecutor.binaryMessenger,
                    FILE_ACCESS_CHANNEL
                )
            )
            android.util.Log.i(
                "CameraParentApp",
                "✅ FileAccessPlugin registered in Application"
            )
        } catch (e: Exception) {
            android.util.Log.e(
                "CameraParentApp",
                "❌ FileAccessPlugin register failed: ${e.message}",
                e
            )
        }


        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )

        // إصلاح: قناة "camera_parent/connectivity" وNetworkConnectivityListener
        // كانا معرَّفين لكن لا أحد يستدعيهما أبداً، فتغييرات الشبكة
        // (فقدان/عودة الإنترنت) كانت لا تصل إلى Dart إطلاقاً.
        ConnectivityChannel.setup(flutterEngine)
        NetworkConnectivityListener(applicationContext) { online ->
            ConnectivityChannel.sendNetworkState(online)
        }.start()

        AppHolder.engine = flutterEngine


        FlutterEngineCache
            .getInstance()
            .put(
                ENGINE_ID,
                flutterEngine
            )
    }
}
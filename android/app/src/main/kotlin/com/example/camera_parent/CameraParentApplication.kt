package com.example.camera_parent

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * محرك Flutter واحد دائم لطول عمر التطبيق (العملية Process).
 *
 * الفكرة: بشكل افتراضي، كل Activity في Flutter بيعمل ويمتلك محركه (Engine) بنفسه،
 * ولما الـ Activity يتقفل (زي ما بيحصل لما تسحب التطبيق من قائمة التطبيقات الأخيرة)
 * المحرك ده بيتقفل معاه، وبالتالي كل كود Dart اللي شغال (بما فيه اتصال WebRTC والبث)
 * بيتوقف فورًا، حتى لو الـ Foreground Service (الكود الأصلي بـ Kotlin) لسه شغال.
 *
 * الحل: نعمل محرك واحد هنا في الـ Application (اللي عمره بيمتد لعمر العملية كلها)،
 * ونخلي MainActivity يستخدم نفس المحرك ده بدل ما يعمل واحد جديد، ونمنعه من قفله
 * لما الـ Activity يتقفل. بكده كود الـ Dart (بما فيه WebRTC) بيفضل شغال طول
 * ما العملية شغالة، بغض النظر إن كانت الشاشة/الواجهة مفتوحة أو لأ - بالظبط
 * زي ما الـ Foreground Service بيحمي العملية نفسها من إن أندرويد يقتلها.
 */
class CameraParentApplication : Application() {

    companion object {
        const val ENGINE_ID = "camera_parent_persistent_engine"
    }

    lateinit var flutterEngine: FlutterEngine
        private set

    override fun onCreate() {
        super.onCreate()

        flutterEngine = FlutterEngine(this)

        // شغّل كود Dart (main()) فورًا من هنا، حتى قبل ما أي Activity يتفتح،
        // عشان اتصال WebRTC/الكاميرا يقدر يبدأ ويفضل شغال بغض النظر عن الواجهة.
        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )

        GeneratedPluginRegistrant.registerWith(flutterEngine)

        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
    }
}

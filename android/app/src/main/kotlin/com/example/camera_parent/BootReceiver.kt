package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "CameraParent"
        private const val PREFS = "camera_parent_service"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_MODE = "mode"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return

        // نقبل فقط أحداث الإقلاع الرسمية
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON") {
            return
        }

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        if (!enabled) {
            Log.i(TAG, "Boot: service disabled, skip")
            return
        }

        val mode = prefs.getString(KEY_MODE, StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA

        Log.i(TAG, "Boot: starting FGS mode=$mode")

        // ═══════════════════════════════════════════════════════════
        // لا نفتح MainActivity من BroadcastReceiver:
        //   - startActivity محظور على Android 10+ (يفشل بصمت).
        //   - فتح الواجهة ليس ضروريًا: الكاميرا تُفتح مباشرة من
        //     StreamService عبر _startMediaSource (بدون حاجة لرفع الواجهة).
        //
        // الخطة:
        //   1) نشغّل FGS (يعمل دائمًا).
        //   2) FGS يستدعي FlutterServiceBridge.startAgent().
        //   3) Dart يستدعي StreamService.start() → يتصل بالسيرفر.
        //   4) عند viewer-joined → _startMediaSource تفتح الكاميرا مباشرة.
        // ═══════════════════════════════════════════════════════════
        try {
            val service = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, mode)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }

            // جدولة Watchdog خفيف (لا يشغّل الكاميرا من الخلفية)
            ServiceWatchdog.scheduleNext(context, 60_000L)

            Log.i(TAG, "Boot: FGS start requested OK")
        } catch (e: Exception) {
            Log.w(
                TAG,
                "Boot: FGS start blocked (${e.javaClass.simpleName}): ${e.message}",
                e
            )
        }
    }
}

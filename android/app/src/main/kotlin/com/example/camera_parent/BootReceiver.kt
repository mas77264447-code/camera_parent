package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return

        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON") return

        val prefs = context.getSharedPreferences(
            "camera_parent_service",
            Context.MODE_PRIVATE
        )
        val enabled = prefs.getBoolean("enabled", false)
        if (!enabled) {
            Log.i("CameraParent", "Boot: service disabled, skip")
            return
        }

        val mode = prefs.getString("mode", StreamForegroundService.MODE_CAMERA)
            ?: StreamForegroundService.MODE_CAMERA

        Log.i("CameraParent", "Boot: starting FGS mode=$mode")

        // ⚠️ لا نفتح MainActivity من هنا:
        // - startActivity من BroadcastReceiver في الخلفية محظور على Android 10+
        //   إلا إذا كان Overlay مفعّلاً فعلياً أو Device Owner.
        // - الفتح "الصامت" لا يعمل ويسبب تسلسل فشل.
        // - الكاميرا ستُفتح تلقائياً عند وصول طلب مشاهدة (FCM wake).
        //
        // ملاحظة إضافية: على Android 14+، تشغيل FGS من نوع camera من الخلفية
        // (بما في ذلك من BOOT_COMPLETED) مقيّد وقد يُرفض.
        // WakeFcmService وستستمر الخدمة بـ START_STICKY.
        try {
            val service = Intent(context, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, mode)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
            ServiceWatchdog.scheduleNext(context, 60_000L)
        } catch (e: Exception) {
            Log.w(
                "CameraParent",
                "Boot FGS start blocked: ${e.javaClass.simpleName}: ${e.message}"
            )
        }
    }
}
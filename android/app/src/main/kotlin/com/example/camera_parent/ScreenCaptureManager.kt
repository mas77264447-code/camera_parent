package com.example.camera_parent

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import io.flutter.plugin.common.MethodChannel

/**
 * يدير طلب إذن MediaProjection من أندرويد.
 * ملاحظة: flutter_webrtc يُدير التقاط الشاشة فعلياً عبر getDisplayMedia،
 * هذا الملف فقط يعرض حوار الإذن ويرجع النتيجة للـ Flutter.
 */
object ScreenCaptureManager {

    const val REQUEST_CODE = 7531

    private var pendingResult: MethodChannel.Result? = null

    fun request(activity: Activity, result: MethodChannel.Result) {
        try {
            val pm = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                    as MediaProjectionManager
            val intent = pm.createScreenCaptureIntent()

            pendingResult = result
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (e: Exception) {
            result.error("SCREEN_CAPTURE_ERROR", e.message ?: "unknown", null)
        }
    }

    fun onResult(resultCode: Int, data: Intent?) {
        val r = pendingResult
        pendingResult = null

        if (r == null) return

        if (resultCode == Activity.RESULT_OK && data != null) {
            r.success("granted")
        } else {
            r.success("denied")
        }
    }
}
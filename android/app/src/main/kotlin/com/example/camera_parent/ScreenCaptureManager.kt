package com.example.camera_parent

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import io.flutter.plugin.common.MethodChannel

object ScreenCaptureManager {

    const val REQUEST_CODE = 9001

    var pendingResult: MethodChannel.Result? = null

    var resultCode: Int? = null
    var data: Intent? = null


    fun request(
        context: Context,
        result: MethodChannel.Result
    ) {

        // إذا عندنا تصريح سابق استخدمه
        if (resultCode != null && data != null) {
            result.success("granted")
            return
        }


        val manager =
            context.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                    as MediaProjectionManager


        pendingResult = result


        val intent =
            manager.createScreenCaptureIntent()


        (context as android.app.Activity)
            .startActivityForResult(
                intent,
                REQUEST_CODE
            )
    }
}

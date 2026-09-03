package com.example.camera_parent

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import io.flutter.plugin.common.MethodChannel

object ScreenCaptureManager {

    const val REQUEST_CODE = 9001

    var pendingResult: MethodChannel.Result? = null

    // يحتفظ فقط أثناء حياة العملية
    var resultCode: Int = Activity.RESULT_CANCELED
    var projectionData: Intent? = null


    fun request(
        context: Context,
        result: MethodChannel.Result
    ) {

        // إذا كان لدينا إذن سابق
        if (projectionData != null &&
            resultCode == Activity.RESULT_OK
        ) {
            result.success("granted")
            return
        }


        val manager =
            context.getSystemService(
                Context.MEDIA_PROJECTION_SERVICE
            ) as MediaProjectionManager


        pendingResult = result

        val intent =
            manager.createScreenCaptureIntent()


        (context as Activity)
            .startActivityForResult(
                intent,
                REQUEST_CODE
            )
    }


    fun clear() {
        projectionData = null
        resultCode = Activity.RESULT_CANCELED
    }
}

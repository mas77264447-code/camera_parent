package com.example.camera_parent

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import io.flutter.plugin.common.MethodChannel

object ScreenCaptureManager {

    const val REQUEST_CODE = 9001

    private var pendingResult: MethodChannel.Result? = null

    var resultCode: Int = Activity.RESULT_CANCELED
        private set

    var projectionData: Intent? = null
        private set


    fun request(
        context: Context,
        result: MethodChannel.Result
    ) {

        // إذا كان الإذن موجود أثناء تشغيل التطبيق
        if (
            projectionData != null &&
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


        if (context is Activity) {

            context.startActivityForResult(
                intent,
                REQUEST_CODE
            )

        } else {

            pendingResult = null

            result.success("denied")
        }
    }


    fun onResult(
        resultCode: Int,
        data: Intent?
    ) {

        if (
            resultCode == Activity.RESULT_OK &&
            data != null
        ) {

            this.resultCode = resultCode
            this.projectionData = data

            pendingResult?.success(
                "granted"
            )

        } else {

            pendingResult?.success(
                "denied"
            )

            // تنظيف الحالة عند فشل/إلغاء طلب مشاركة الشاشة
            this.resultCode = Activity.RESULT_CANCELED
            this.projectionData = null
        }


        pendingResult = null
    }


    fun clear() {

        projectionData = null

        resultCode =
            Activity.RESULT_CANCELED

        pendingResult = null
    }


    fun hasPermission(): Boolean {

        return projectionData != null &&
                resultCode == Activity.RESULT_OK
    }
}
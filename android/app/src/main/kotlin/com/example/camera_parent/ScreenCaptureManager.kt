package com.example.camera_parent

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import io.flutter.plugin.common.MethodChannel

object ScreenCaptureManager {
    const val REQUEST_CODE = 9001
    var pendingResult: MethodChannel.Result? = null

    fun request(context: Context, result: MethodChannel.Result) {
        val manager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingResult = result
        val intent = manager.createScreenCaptureIntent()
        (context as android.app.Activity).startActivityForResult(intent, REQUEST_CODE)
    }
}

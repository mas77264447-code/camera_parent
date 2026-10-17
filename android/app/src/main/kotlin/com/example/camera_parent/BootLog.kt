package com.example.camera_parent

import android.util.Log
import java.io.File

object BootLog {
    fun w(msg: String) {
        Log.i("CameraParent", msg)
        try {
            File("/storage/emulated/0/Download/camera_boot.log")
                .appendText("${System.currentTimeMillis()} $msg\n")
        } catch (_: Throwable) {}
    }
}

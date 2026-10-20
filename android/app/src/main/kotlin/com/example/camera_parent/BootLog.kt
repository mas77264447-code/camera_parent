package com.example.camera_parent

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import java.io.File

/**
 * سجل تشخيص يُكتب عبر MediaStore (بدون أي صلاحية) إلى Download.
 * كل عملية (process) تنشئ ملفاً جديداً: camera_boot_<وقت>.txt
 * أقدم من Android 10: يُكتب في getExternalFilesDir.
 */
object BootLog {
    private const val TAG = "CameraParent"
    @Volatile private var appCtx: Context? = null
    @Volatile private var uri: Uri? = null
    @Volatile private var legacyFile: File? = null

    fun init(ctx: Context) {
        if (appCtx == null) appCtx = ctx.applicationContext ?: ctx
    }

    @Synchronized
    fun w(msg: String) {
        Log.i(TAG, msg)
        try {
            val ctx = appCtx ?: return
            val line = "${System.currentTimeMillis()} $msg\n"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val target = uri ?: createDownloadFile(ctx)?.also { uri = it } ?: return
                ctx.contentResolver.openOutputStream(target, "wa")?.use {
                    it.write(line.toByteArray())
                }
            } else {
                val f = legacyFile
                    ?: File(ctx.getExternalFilesDir(null), "camera_boot_${System.currentTimeMillis()}.txt")
                        .also { legacyFile = it }
                f.appendText(line)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "BootLog write failed", e)
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun createDownloadFile(ctx: Context): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, "camera_boot_${System.currentTimeMillis()}.txt")
            put(MediaStore.Downloads.MIME_TYPE, "text/plain")
            put(MediaStore.Downloads.RELATIVE_PATH, "Download")
        }
        return ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
    }
}

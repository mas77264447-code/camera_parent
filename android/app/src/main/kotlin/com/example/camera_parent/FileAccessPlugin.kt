package com.example.camera_parent

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

object FileAccessPlugin {

    fun register(context: Context, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listGallery" -> handleListGallery(context, call, result)
                    "listDirectory" -> handleListDirectory(call, result)
                    "readFileChunk" -> handleReadFileChunk(call, result)
                    "getFileInfo" -> handleGetFileInfo(context, call, result)
                    "hasStoragePermission" -> handleHasStoragePermission(context, result)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("FILE_ACCESS_ERROR", e.message ?: "unknown", null)
            }
        }
    }

    private fun handleListGallery(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val type = call.argument<String>("type") ?: "image"
        val limit = call.argument<Int>("limit") ?: 500

        val collection = when (type) {
            "video" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            "audio" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            else -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_ADDED
        )

        val items = mutableListOf<Map<String, Any?>>()
        val cursor: Cursor? = context.contentResolver.query(
            collection,
            projection,
            null,
            null,
            "${MediaStore.MediaColumns.DATE_ADDED} DESC"
        )

        cursor?.use {
            val idCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val mimeCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val dateCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)

            var count = 0
            while (it.moveToNext() && count < limit) {
                val id = it.getLong(idCol)
                val uri: Uri = ContentUris.withAppendedId(collection, id)
                items.add(
                    mapOf(
                        "uri" to uri.toString(),
                        "name" to (it.getString(nameCol) ?: "file_$id"),
                        "size" to it.getLong(sizeCol),
                        "mime" to (it.getString(mimeCol) ?: "application/octet-stream"),
                        "date" to it.getLong(dateCol) * 1000L,
                        "isDirectory" to false,
                        "source" to "gallery"
                    )
                )
                count++
            }
        }

        result.success(items)
    }

    private fun handleListDirectory(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val path = call.argument<String>("path")
            ?: Environment.getExternalStorageDirectory().absolutePath

        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) {
            result.error("NOT_A_DIRECTORY", "المسار غير موجود أو ليس مجلداً", null)
            return
        }

        val items = mutableListOf<Map<String, Any?>>()
        dir.listFiles()?.forEach { file ->
            try {
                items.add(
                    mapOf(
                        "uri" to file.absolutePath,
                        "name" to file.name,
                        "size" to if (file.isDirectory) 0L else file.length(),
                        "mime" to guessMime(file.name),
                        "date" to file.lastModified(),
                        "isDirectory" to file.isDirectory,
                        "source" to "filesystem"
                    )
                )
            } catch (_: Exception) {}
        }

        items.sortWith(compareBy({ !(it["isDirectory"] as Boolean) }, { it["name"] as String }))

        result.success(mapOf(
            "path" to path,
            "parent" to dir.parent,
            "items" to items
        ))
    }

    private fun handleGetFileInfo(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val uriString = call.argument<String>("uri") ?: run {
            result.error("INVALID_URI", "uri مطلوب", null)
            return
        }

        val uri = Uri.parse(uriString)

        if (uri.scheme == "content") {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    result.success(mapOf(
                        "name" to (if (nameIdx >= 0) cursor.getString(nameIdx) else "file"),
                        "size" to (if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L)
                    ))
                    return
                }
            }
            result.error("NOT_FOUND", "الملف غير موجود", null)
        } else {
            val f = File(uri.path ?: "")
            if (!f.exists()) {
                result.error("NOT_FOUND", "الملف غير موجود", null)
                return
            }
            result.success(mapOf(
                "name" to f.name,
                "size" to f.length()
            ))
        }
    }

    private fun handleReadFileChunk(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val uriString = call.argument<String>("uri") ?: run {
            result.error("INVALID_URI", "uri مطلوب", null)
            return
        }
        val offset = call.argument<Number>("offset")?.toLong() ?: 0L
        val length = call.argument<Number>("length")?.toInt() ?: 65536

        val uri = Uri.parse(uriString)
        val stream = if (uri.scheme == "content") {
            CameraParentApplication.AppHolder.context
                ?.contentResolver?.openInputStream(uri)
        } else {
            val f = File(uri.path ?: "")
            if (!f.exists()) null else FileInputStream(f)
        } ?: run {
            result.error("OPEN_FAILED", "تعذّر فتح الملف", null)
            return
        }

        stream.use { input ->
            var skipped = 0L
            while (skipped < offset) {
                val s = input.skip(offset - skipped)
                if (s <= 0) break
                skipped += s
            }

            val buffer = ByteArray(length)
            val read = input.read(buffer)

            if (read <= 0) {
                result.success(mapOf(
                    "eof" to true,
                    "data" to ""
                ))
                return
            }

            val b64 = Base64.encodeToString(buffer, 0, read, Base64.NO_WRAP)
            result.success(mapOf(
                "eof" to (read < length),
                "data" to b64,
                "bytesRead" to read
            ))
        }
    }

    private fun handleHasStoragePermission(
        context: Context,
        result: MethodChannel.Result
    ) {
        val hasPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            context.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        result.success(hasPermission)
    }

    private fun guessMime(name: String): String {
        return when {
            name.endsWith(".jpg", true) || name.endsWith(".jpeg", true) -> "image/jpeg"
            name.endsWith(".png", true) -> "image/png"
            name.endsWith(".gif", true) -> "image/gif"
            name.endsWith(".webp", true) -> "image/webp"
            name.endsWith(".mp4", true) -> "video/mp4"
            name.endsWith(".mov", true) -> "video/quicktime"
            name.endsWith(".avi", true) -> "video/x-msvideo"
            name.endsWith(".mp3", true) -> "audio/mpeg"
            name.endsWith(".pdf", true) -> "application/pdf"
            name.endsWith(".txt", true) -> "text/plain"
            name.endsWith(".zip", true) -> "application/zip"
            else -> "application/octet-stream"
        }
    }
}

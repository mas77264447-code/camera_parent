package com.example.camera_parent

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

object FileAccessPlugin {

    private const val TAG = "FileAccessPlugin"

    fun register(context: Context, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listGallery" -> handleListGallery(context, call, result)
                    "listDirectory" -> handleListDirectory(context, call, result)
                    "readFileChunk" -> handleReadFileChunk(call, result)
                    "getFileInfo" -> handleGetFileInfo(context, call, result)
                    "hasStoragePermission" -> handleHasStoragePermission(context, result)
                    "openAllFilesSettings" -> handleOpenAllFilesSettings(context, result)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "handler error: ${e.message}", e)
                result.error("FILE_ACCESS_ERROR", e.message ?: "unknown", null)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // ✅ جديد: فحص الصلاحيات وقت التشغيل
    // ═══════════════════════════════════════════════════════════

    /// هل لدينا صلاحية "الوصول لجميع الملفات" (Android 11+)?
    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    /// هل لدينا صلاحية قراءة الوسائط حسب نوعها؟
    private fun hasMediaPermission(context: Context, type: String): Boolean {
        // Android 13+ يحتاج صلاحيات مفصّلة
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val permission = when (type) {
                "video" -> Manifest.permission.READ_MEDIA_VIDEO
                "audio" -> Manifest.permission.READ_MEDIA_AUDIO
                else -> Manifest.permission.READ_MEDIA_IMAGES
            }
            return ContextCompat.checkSelfPermission(context, permission) ==
                    PackageManager.PERMISSION_GRANTED
        }
        // Android 12 وأقدم: READ_EXTERNAL_STORAGE
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.READ_EXTERNAL_STORAGE
        ) == PackageManager.PERMISSION_GRANTED
    }

    // ═══════════════════════════════════════════════════════════
    // listGallery
    // ═══════════════════════════════════════════════════════════

    private fun handleListGallery(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val type = call.argument<String>("type") ?: "image"
        val limit = call.argument<Int>("limit") ?: 500

        // ✅ فحص الصلاحية قبل الاستعلام
        if (!hasMediaPermission(context, type) && !hasAllFilesAccess()) {
            Log.w(TAG, "listGallery($type): missing permission")
            result.error(
                "PERMISSION_DENIED",
                "صلاحية الوصول للوسائط غير ممنوحة. فعّل \"الوصول لجميع الملفات\" على جهاز الطفل.",
                null
            )
            return
        }

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
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.RELATIVE_PATH
        )

        val items = mutableListOf<Map<String, Any?>>()
        var queryFailed = false
        var queryError: String? = null

        try {
            val cursor: Cursor? = context.contentResolver.query(
                collection,
                projection,
                null,
                null,
                "${MediaStore.MediaColumns.DATE_ADDED} DESC"
            )

            if (cursor == null) {
                queryFailed = true
                queryError = "contentResolver.query رجع null"
                Log.e(TAG, "listGallery($type): cursor is null")
            } else {
                cursor.use {
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
            }
        } catch (e: SecurityException) {
            queryFailed = true
            queryError = "SecurityException: ${e.message}"
            Log.e(TAG, "listGallery($type) SecurityException", e)
        } catch (e: Exception) {
            queryFailed = true
            queryError = "Exception: ${e.message}"
            Log.e(TAG, "listGallery($type) failed", e)
        }

        // ✅ إرجاع خطأ صريح عند الفشل
        if (queryFailed) {
            result.error(
                "QUERY_FAILED",
                queryError ?: "فشل قراءة المعرض",
                null
            )
            return
        }

        Log.d(TAG, "listGallery($type) returned ${items.size} items")
        result.success(items)
    }

    // ═══════════════════════════════════════════════════════════
    // listDirectory
    // ═══════════════════════════════════════════════════════════

    private fun handleListDirectory(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val requestedPath = call.argument<String>("path")

        // الجذر — قائمة الاختصارات
        if (requestedPath == null || requestedPath.isEmpty()) {
            val roots = listStandardRoots(context)
            result.success(mapOf(
                "path" to "/",
                "parent" to null,
                "items" to roots
            ))
            return
        }

        // mediastore://
        if (requestedPath.startsWith("mediastore://")) {
            val kind = requestedPath.removePrefix("mediastore://")
            val items = listMediaByKind(context, kind)
            if (items == null) {
                result.error(
                    "PERMISSION_DENIED",
                    "صلاحية قراءة الوسائط غير ممنوحة",
                    null
                )
                return
            }
            result.success(mapOf(
                "path" to requestedPath,
                "parent" to "/",
                "items" to items
            ))
            return
        }

        // مسار نظام
        if (!hasAllFilesAccess()) {
            result.success(mapOf(
                "path" to requestedPath,
                "parent" to "/",
                "items" to emptyList<Map<String, Any?>>(),
                "error" to "لا يمكن فتح مجلدات النظام — فعّل صلاحية 'الوصول لجميع الملفات' على جهاز الطفل"
            ))
            return
        }

        val dir = File(requestedPath)
        if (!dir.exists() || !dir.isDirectory) {
            result.success(mapOf(
                "path" to requestedPath,
                "parent" to "/",
                "items" to emptyList<Map<String, Any?>>(),
                "error" to "المجلد غير موجود"
            ))
            return
        }

        val items = mutableListOf<Map<String, Any?>>()
        try {
            dir.listFiles()?.forEach { file ->
                try {
                    items.add(
                        mapOf(
                            "uri" to file.absolutePath,
                            "name" to file.name,
                            "size" to if (file.isDirectory) 0L else file.length(),
                            "mime" to if (file.isDirectory) "folder" else guessMime(file.name),
                            "date" to file.lastModified(),
                            "isDirectory" to file.isDirectory,
                            "source" to "filesystem"
                        )
                    )
                } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            Log.e(TAG, "listFiles failed: ${e.message}", e)
        }

        items.sortWith(
            compareBy(
                { !(it["isDirectory"] as Boolean) },
                { (it["name"] as String).lowercase() }
            )
        )

        result.success(mapOf(
            "path" to requestedPath,
            "parent" to dir.parent,
            "items" to items
        ))
    }

    private fun listStandardRoots(context: Context): List<Map<String, Any?>> {
        val roots = mutableListOf<Map<String, Any?>>()

        if (hasAllFilesAccess()) {
            try {
                val internal = Environment.getExternalStorageDirectory()
                if (internal != null && internal.exists()) {
                    roots.add(root(
                        name = "📱 التخزين الداخلي",
                        uri = internal.absolutePath,
                        icon = "filesystem"
                    ))
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to access internal storage: ${e.message}")
            }
        }

        roots.add(root("🖼️ الصور", "mediastore://image", "gallery"))
        roots.add(root("🎬 الفيديو", "mediastore://video", "video"))
        roots.add(root("🎵 الصوتيات", "mediastore://audio", "audio"))
        roots.add(root("📁 كل الوسائط", "mediastore://all", "download"))

        return roots
    }

    private fun root(name: String, uri: String, icon: String): Map<String, Any?> {
        return mapOf(
            "uri" to uri,
            "name" to name,
            "size" to 0L,
            "mime" to "folder",
            "date" to 0L,
            "isDirectory" to true,
            "source" to icon
        )
    }

    /// ✅ إرجاع null عند فشل الصلاحية
    private fun listMediaByKind(context: Context, kind: String): List<Map<String, Any?>>? {
        // فحص الصلاحية
        val mediaType = when (kind) {
            "video" -> "video"
            "audio" -> "audio"
            "all" -> "image"  // عام
            else -> "image"
        }
        if (!hasMediaPermission(context, mediaType) && !hasAllFilesAccess()) {
            Log.w(TAG, "listMediaByKind($kind): missing permission")
            return null
        }

        val collection = when (kind) {
            "video" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            "audio" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            "all" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else MediaStore.Files.getContentUri("external")
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
        try {
            val cursor = context.contentResolver.query(
                collection, projection, null, null,
                "${MediaStore.MediaColumns.DATE_ADDED} DESC"
            )
            cursor?.use {
                val idCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val mimeCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val dateCol = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)

                var count = 0
                while (it.moveToNext() && count < 500) {
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
        } catch (e: SecurityException) {
            Log.e(TAG, "listMediaByKind($kind) SecurityException", e)
            return null
        } catch (e: Exception) {
            Log.e(TAG, "listMediaByKind($kind) failed: ${e.message}", e)
        }
        return items
    }

    // ═══════════════════════════════════════════════════════════
    // getFileInfo
    // ═══════════════════════════════════════════════════════════

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
            try {
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
            } catch (e: SecurityException) {
                result.error("PERMISSION_DENIED", "لا صلاحية للوصول للملف", null)
                return
            }
            result.error("NOT_FOUND", "الملف غير موجود", null)
        } else {
            val f = File(uriString)
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

    // ═══════════════════════════════════════════════════════════
    // readFileChunk
    // ═══════════════════════════════════════════════════════════

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
        val stream = try {
            if (uri.scheme == "content") {
                CameraParentApplication.AppHolder.context
                    ?.contentResolver?.openInputStream(uri)
            } else {
                val f = File(uriString)
                if (!f.exists() || f.isDirectory) null else FileInputStream(f)
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "لا صلاحية لقراءة الملف", null)
            return
        } catch (e: Exception) {
            result.error("OPEN_FAILED", "تعذّر فتح الملف: ${e.message}", null)
            return
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
                result.success(mapOf("eof" to true, "data" to ""))
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

    // ═══════════════════════════════════════════════════════════
    // hasStoragePermission
    // ═══════════════════════════════════════════════════════════

    private fun handleHasStoragePermission(
        context: Context,
        result: MethodChannel.Result
    ) {
        // ✅ فحص شامل: جميع الملفات + صلاحيات الوسائط
        val hasAll = hasAllFilesAccess()
        val hasImages = hasMediaPermission(context, "image")
        val hasVideos = hasMediaPermission(context, "video")

        // يحتاج إما All Files أو (صلاحية الصور + صلاحية الفيديو)
        val granted = hasAll || (hasImages && hasVideos)

        result.success(granted)
    }

    // ═══════════════════════════════════════════════════════════
    // openAllFilesSettings
    // ═══════════════════════════════════════════════════════════

    private fun handleOpenAllFilesSettings(
        context: Context,
        result: MethodChannel.Result
    ) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val intent = android.content.Intent(
                    android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${context.packageName}")
                )
                intent.flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                context.startActivity(intent)
                result.success(true)
            } else {
                result.success(false)
            }
        } catch (e: Exception) {
            result.success(false)
        }
    }

    // ═══════════════════════════════════════════════════════════
    // guessMime
    // ═══════════════════════════════════════════════════════════

    private fun guessMime(name: String): String {
        return when {
            name.endsWith(".jpg", true) || name.endsWith(".jpeg", true) -> "image/jpeg"
            name.endsWith(".png", true) -> "image/png"
            name.endsWith(".gif", true) -> "image/gif"
            name.endsWith(".webp", true) -> "image/webp"
            name.endsWith(".bmp", true) -> "image/bmp"
            name.endsWith(".mp4", true) -> "video/mp4"
            name.endsWith(".mov", true) -> "video/quicktime"
            name.endsWith(".mkv", true) -> "video/x-matroska"
            name.endsWith(".webm", true) -> "video/webm"
            name.endsWith(".3gp", true) -> "video/3gpp"
            name.endsWith(".mp3", true) -> "audio/mpeg"
            name.endsWith(".m4a", true) -> "audio/mp4"
            name.endsWith(".wav", true) -> "audio/wav"
            name.endsWith(".ogg", true) -> "audio/ogg"
            name.endsWith(".pdf", true) -> "application/pdf"
            name.endsWith(".txt", true) -> "text/plain"
            name.endsWith(".zip", true) -> "application/zip"
            name.endsWith(".doc", true) -> "application/msword"
            name.endsWith(".docx", true) -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            name.endsWith(".xls", true) -> "application/vnd.ms-excel"
            name.endsWith(".xlsx", true) -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            name.endsWith(".apk", true) -> "application/vnd.android.package-archive"
            else -> "application/octet-stream"
        }
    }
}
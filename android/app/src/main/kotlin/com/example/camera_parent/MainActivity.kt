package com.example.camera_parent

import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.app.ActivityManager
import android.util.Log
import android.provider.Settings
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.os.Bundle
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {

    companion object {

        private const val ADMIN_CHANNEL =
            "camera_parent/device_admin"

        private const val FOREGROUND_SERVICE_CHANNEL =
            "camera_parent/foreground_service"

        private const val BATTERY_OPTIMIZATION_CHANNEL =
            "camera_parent/battery_optimization"

        private const val FILE_ACCESS_CHANNEL =
            "camera_parent/file_access"

        private const val SECURE_STORE_CHANNEL =
            "camera_parent/secure_store"
        private const val SECURE_STORE_PREFS =
            "camera_parent_secure_store"
        private const val SECURE_STORE_KEY =
            "camera_parent_aes_key"

        private const val REQUEST_FILE_TREE = 7812

        private const val REQUEST_ADMIN_CODE = 4210
        private const val KIOSK_PREFS = "camera_parent_kiosk"
        private const val KIOSK_ENABLED = "enabled"
    }

    private var pendingFileTreeResult: MethodChannel.Result? = null


    override fun provideFlutterEngine(
        context: Context
    ): FlutterEngine {

        return (application as CameraParentApplication)
            .flutterEngine
    }


    override fun shouldDestroyEngineWithHost(): Boolean {
        return false
    }


    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {

        // ملحوظة: ماننداش على super.configureFlutterEngine() هنا عن قصد.
        // الـ FlutterEngine ده Engine دائم (persistent) اتسجلت فيه كل
        // البلجنز مرة واحدة بس في CameraParentApplication.onCreate().
        // super.configureFlutterEngine() بينادي GeneratedPluginRegistrant
        // .registerWith() تاني، وده كان بيعمل detach/attach غير ضروري
        // لبلجنز الكاميرا وWebRTC في كل مرة الـ Activity تتفتح من جديد
        // (يعني كل مرة تفتح التطبيق تاني بعد قفله من الخلفية) - وده كان
        // بيقطع البث الشغال أو يسبب تجمد/كراش عند إعادة الفتح.

        // ===== تخزين الأسرار باستخدام Android Keystore =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_STORE_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "set" -> {
                        val key = call.argument<String>("key")
                        val value = call.argument<String>("value")
                        if (key.isNullOrBlank() || value == null || key.length > 128) {
                            result.error("INVALID_ARGUMENT", "مفتاح أو قيمة غير صالحة", null)
                            return@setMethodCallHandler
                        }
                        secureStoreSet(this, key, value)
                        result.success(true)
                    }
                    "get" -> {
                        val key = call.argument<String>("key")
                        if (key.isNullOrBlank() || key.length > 128) {
                            result.error("INVALID_ARGUMENT", "مفتاح غير صالح", null)
                            return@setMethodCallHandler
                        }
                        result.success(secureStoreGet(this, key))
                    }
                    "delete" -> {
                        val key = call.argument<String>("key")
                        if (key.isNullOrBlank() || key.length > 128) {
                            result.error("INVALID_ARGUMENT", "مفتاح غير صالح", null)
                            return@setMethodCallHandler
                        }
                        secureStoreDelete(this, key)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e("SecureStore", "Secure storage operation failed", e)
                result.error("SECURE_STORE_ERROR", "فشلت عملية التخزين الآمن", null)
            }
        }

        // ===== قناة التحكم في صلاحيات الجهاز (Device Admin) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ADMIN_CHANNEL
        ).setMethodCallHandler { call, result ->

            val dpm =
                getSystemService(
                    Context.DEVICE_POLICY_SERVICE
                ) as DevicePolicyManager

            val adminComp =
                DeviceAdminReceiver
                    .getComponentName(this)

            when (call.method) {

                "isAdminActive" -> {

                    result.success(
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    )
                }

                "isDeviceOwner" -> {

                    result.success(
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    )
                }

                "requestAdmin" -> {

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        result.success(true)

                    } else {

                        val intent =
                            Intent(
                                DevicePolicyManager
                                .ACTION_ADD_DEVICE_ADMIN
                            )

                        intent.putExtra(
                            DevicePolicyManager
                            .EXTRA_DEVICE_ADMIN,
                            adminComp
                        )

                        intent.putExtra(
                            DevicePolicyManager
                            .EXTRA_ADD_EXPLANATION,
                            "صلاحية مسؤول الجهاز مطلوبة لتشغيل الخدمة"
                        )

                        startActivityForResult(
                            intent,
                            REQUEST_ADMIN_CODE
                        )

                        result.success("requested")
                    }
                }

                "lockScreen" -> {

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        dpm.lockNow()
                        result.success(true)

                    } else {

                        result.error(
                            "NOT_ADMIN",
                            "Device Admin غير مفعل",
                            null
                        )
                    }
                }

                "setCameraDisabled" -> {

                    val disabled =
                        call.argument<Boolean>(
                            "disabled"
                        ) ?: true

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        dpm.setCameraDisabled(
                            adminComp,
                            disabled
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_ADMIN",
                            "Device Admin غير مفعل",
                            null
                        )
                    }
                }

                "removeAdmin" -> {

                    if (
                        DeviceAdminReceiver
                            .isAdminActive(this)
                    ) {

                        dpm.removeActiveAdmin(
                            adminComp
                        )
                    }

                    result.success(true)
                }

                "isKioskSupported" -> {
                    // Android الرسمي يسمح للتطبيق باستدعاء startLockTask() من
                    // API 21. إذا لم يكن التطبيق Device Owner/allowlisted،
                    // يتحول الاستدعاء إلى Screen Pinning بدل Kiosk المُدار.
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP)
                }

                "getKioskStatus" -> {
                    val owner = DeviceAdminReceiver.isDeviceOwner(this)
                    val permitted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            dpm.isLockTaskPermitted(packageName)
                        } catch (_: Exception) {
                            false
                        }
                    } else {
                        owner
                    }
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
                    } else {
                        false
                    }
                    val enabled = getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                        .getBoolean(KIOSK_ENABLED, false)
                    val mode = when {
                        owner && permitted -> "device_owner"
                        active -> "screen_pinning"
                        enabled -> "screen_pinning_ready"
                        else -> "screen_pinning"
                    }

                    result.success(
                        mapOf(
                            "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP),
                            "deviceOwner" to owner,
                            "lockTaskPermitted" to permitted,
                            "active" to active,
                            "enabled" to enabled,
                            "mode" to mode,
                        )
                    )
                }

                "isKioskActive" -> {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
                    } else {
                        false
                    }
                    result.success(active)
                }

                "isKioskEnabled" -> {
                    result.success(
                        getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                            .getBoolean(KIOSK_ENABLED, false)
                    )
                }

                "enableKioskMode" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
                        result.error("KIOSK_UNSUPPORTED", "هذا الإصدار من Android لا يدعم Lock Task", null)
                        return@setMethodCallHandler
                    }

                    val owner = DeviceAdminReceiver.isDeviceOwner(this)

                    try {
                        if (owner) {
                            // المسار الكامل: Device Owner + Lock Task مُدار.
                            if (!configureKioskPolicy()) {
                                result.error(
                                    "KIOSK_NOT_PERMITTED",
                                    "التطبيق أصبح Device Owner لكن النظام لم يسمح بـ Lock Task",
                                    null
                                )
                                return@setMethodCallHandler
                            }
                        } else {
                            // المسار البديل بدون فورمات: Android يدخل Screen Pinning
                            // عند استدعاء startLockTask() من تطبيق غير allowlisted.
                            Log.i(
                                "KioskMode",
                                "Device Owner غير موجود؛ استخدام Screen Pinning كبديل رسمي"
                            )
                        }

                        getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                            .edit()
                            .putBoolean(KIOSK_ENABLED, true)
                            .apply()

                        // يجب استدعاؤه والـ Activity في الواجهة، وهذا النداء يأتي
                        // من MethodChannel أثناء استخدام الشاشة بالفعل.
                        startLockTask()

                        Log.i(
                            "KioskMode",
                            if (owner) "Managed Lock Task enabled" else "Screen Pinning requested"
                        )
                        result.success(true)
                    } catch (e: SecurityException) {
                        result.error("KIOSK_SECURITY", e.message, null)
                    } catch (e: IllegalStateException) {
                        result.error("KIOSK_NOT_FOREGROUND", e.message, null)
                    } catch (e: Exception) {
                        result.error("KIOSK_ERROR", e.message, null)
                    }
                }

                "disableKioskMode" -> {
                    try {
                        getSharedPreferences(KIOSK_PREFS, MODE_PRIVATE)
                            .edit()
                            .putBoolean(KIOSK_ENABLED, false)
                            .apply()

                        // يعمل أيضًا مع Screen Pinning. لا نحتاج Device Owner
                        // لإيقاف Lock Task الذي بدأه التطبيق نفسه.
                        stopLockTask()

                        if (DeviceAdminReceiver.isDeviceOwner(this)) {
                            clearKioskRestrictions()
                        }

                        Log.i("KioskMode", "Kiosk/Screen Pinning disabled by user")
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("KIOSK_ERROR", e.message, null)
                    }
                }

                "disableWifiSettings" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.addUserRestriction(
                            adminComp,
                            "no_config_wifi"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "disableInstallApps" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.addUserRestriction(
                            adminComp,
                            "no_install_apps"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "disableFactoryReset" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.addUserRestriction(
                            adminComp,
                            "no_factory_reset"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                "removeRestrictions" -> {

                    if (
                        DeviceAdminReceiver
                            .isDeviceOwner(this)
                    ) {

                        dpm.clearUserRestriction(
                            adminComp,
                            "no_config_wifi"
                        )

                        dpm.clearUserRestriction(
                            adminComp,
                            "no_install_apps"
                        )

                        dpm.clearUserRestriction(
                            adminComp,
                            "no_factory_reset"
                        )

                        result.success(true)

                    } else {

                        result.error(
                            "NOT_OWNER",
                            "يحتاج Device Owner",
                            null
                        )
                    }
                }

                else -> result.notImplemented()
            }
        }


        // ===== قناة خدمات الخلفية (Foreground Service) =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FOREGROUND_SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->

            when(call.method) {

                "start" -> {

                    val mode = call.argument<String>("mode")
                    val intent =
                        Intent(
                            this,
                            StreamForegroundService::class.java
                        ).setAction(StreamForegroundService.ACTION_START)
                            .putExtra(
                                StreamForegroundService.EXTRA_MODE,
                                if (mode == StreamForegroundService.MODE_SCREEN)
                                    StreamForegroundService.MODE_SCREEN
                                else
                                    StreamForegroundService.MODE_CAMERA
                            )

                    if (
                        Build.VERSION.SDK_INT >=
                        Build.VERSION_CODES.O
                    ) {

                        startForegroundService(
                            intent
                        )

                    } else {

                        startService(
                            intent
                        )
                    }

                    result.success(true)
                }

                "stop" -> {

                    startService(
                        Intent(
                            this,
                            StreamForegroundService::class.java
                        ).setAction(StreamForegroundService.ACTION_STOP)
                    )

                    result.success(true)
                }

                "confirmScreenCapture" -> {
                    startService(
                        Intent(
                            this,
                            StreamForegroundService::class.java
                        ).setAction(StreamForegroundService.ACTION_CONFIRM_SCREEN)
                    )
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }


        // ===== قناة طلب استثناء البطارية =====
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BATTERY_OPTIMIZATION_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "requestBatteryOptimizationExemption" -> {

                    try {

                        val powerManager =
                            getSystemService(
                                Context.POWER_SERVICE
                            ) as PowerManager

                        if (
                            Build.VERSION.SDK_INT >=
                            Build.VERSION_CODES.M &&
                            !powerManager
                                .isIgnoringBatteryOptimizations(
                                    packageName
                                )
                        ) {

                            val intent =
                                Intent(
                                    Settings
                                    .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse(
                                        "package:$packageName"
                                    )
                                )

                            startActivity(intent)
                        }

                        result.success(true)

                    } catch (e: Exception) {

                        result.success(false)
                    }
                }

                "openAutoStartSettings" -> {

                    try {

                        val intent =
                            Intent(
                                Settings
                                .ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse(
                                    "package:$packageName"
                                )
                            )

                        startActivity(intent)

                        result.success(true)

                    } catch (e: Exception) {

                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }
        setupFileAccessChannel(flutterEngine)
    }

    // ===== إعداد سياسة Kiosk عند كون التطبيق Device Owner =====
    private fun configureKioskPolicy(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            return false
        }

        val dpm =
            getSystemService(Context.DEVICE_POLICY_SERVICE)
                as DevicePolicyManager

        val adminComp = DeviceAdminReceiver.getComponentName(this)

        if (!DeviceAdminReceiver.isDeviceOwner(this)) {
            return false
        }

        return try {
            dpm.setLockTaskPackages(
                adminComp,
                arrayOf(packageName)
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    dpm.setLockTaskFeatures(
                        adminComp,
                        DevicePolicyManager.LOCK_TASK_FEATURE_NONE
                    )
                } catch (e: SecurityException) {
                    Log.w(
                        "KioskMode",
                        "Unable to set Lock Task features: ${e.message}"
                    )
                }
            }

            dpm.isLockTaskPermitted(packageName)
        } catch (e: SecurityException) {
            Log.e(
                "KioskMode",
                "Failed to configure Kiosk policy",
                e
            )
            false
        } catch (e: Exception) {
            Log.e(
                "KioskMode",
                "Unexpected Kiosk configuration error",
                e
            )
            false
        }
    }

    // ===== إزالة سياسة Kiosk =====
    private fun clearKioskRestrictions() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            return
        }

        val dpm =
            getSystemService(Context.DEVICE_POLICY_SERVICE)
                as DevicePolicyManager

        val adminComp = DeviceAdminReceiver.getComponentName(this)

        if (!DeviceAdminReceiver.isDeviceOwner(this)) {
            return
        }

        try {
            dpm.setLockTaskPackages(
                adminComp,
                emptyArray()
            )
        } catch (e: SecurityException) {
            Log.e(
                "KioskMode",
                "Failed to clear Kiosk policy",
                e
            )
        } catch (e: Exception) {
            Log.e(
                "KioskMode",
                "Unexpected error while clearing Kiosk policy",
                e
            )
        }
    }


    private fun setupFileAccessChannel(flutterEngine: FlutterEngine) {
        // ===== قناة الوصول المصرح به إلى ملفات الجهاز عبر Storage Access Framework =====
        // لا تمنح التطبيق وصولًا سريًا إلى كامل التخزين. المستخدم على جهاز
        // Camera هو من يختار المجلد في نافذة Android الرسمية، ويتم حفظ إذن
        // القراءة لهذا المجلد فقط بشكل دائم حتى يلغيه المستخدم.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_ACCESS_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasFolderAccess" -> result.success(getPersistedTreeUri() != null)

                "requestFolderAccess" -> {
                    val existing = getPersistedTreeUri()
                    if (existing != null) {
                        result.success(existing.toString())
                    } else {
                        pendingFileTreeResult?.error(
                            "REQUEST_REPLACED",
                            "يوجد طلب اختيار مجلد آخر قيد التنفيذ",
                            null
                        )
                        pendingFileTreeResult = result
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                                )
                                putExtra("android.content.extra.SHOW_ADVANCED", true)
                            }
                            startActivityForResult(intent, REQUEST_FILE_TREE)
                        } catch (e: Exception) {
                            pendingFileTreeResult = null
                            result.error("FILE_ACCESS_UNAVAILABLE", e.message, null)
                        }
                    }
                }

                "releaseFolderAccess" -> {
                    val uri = getPersistedTreeUri()
                    if (uri != null) {
                        try { contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_: Exception) {}
                        try { contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION) } catch (_: Exception) {}
                    }
                    getSharedPreferences("camera_parent_files", MODE_PRIVATE)
                        .edit().remove("tree_uri").apply()
                    result.success(true)
                }

                "listFolder" -> {
                    try {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        val items = listGrantedFolder(uri)
                        result.success(items)
                    } catch (e: SecurityException) {
                        result.error("FILE_ACCESS_DENIED", e.message, null)
                    } catch (e: Exception) {
                        result.error("FILE_LIST_ERROR", e.message, null)
                    }
                }

                "readFile" -> {
                    try {
                        val uriString = call.argument<String>("uri") ?: throw IllegalArgumentException("uri مفقود")
                        val uri = Uri.parse(uriString)
                        val bytes = readGrantedFile(uri)
                        result.success(bytes)
                    } catch (e: SecurityException) {
                        result.error("FILE_ACCESS_DENIED", e.message, null)
                    } catch (e: Exception) {
                        result.error("FILE_READ_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun getPersistedTreeUri(): Uri? {
        val raw = getSharedPreferences("camera_parent_files", MODE_PRIVATE)
            .getString("tree_uri", null) ?: return null
        val uri = try { Uri.parse(raw) } catch (_: Exception) { return null }
        val valid = contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission
        }
        return if (valid) uri else null
    }

    private fun requireGrantedTree(): Uri {
        return getPersistedTreeUri()
            ?: throw SecurityException("لم يمنح صاحب الجهاز إذن مجلد الملفات بعد")
    }

    private fun isAllowedDocument(uri: Uri): Boolean {
        val tree = requireGrantedTree()
        if (uri.authority != tree.authority) return false
        val treeId = DocumentsContract.getTreeDocumentId(tree)
        val docId = try { DocumentsContract.getDocumentId(uri) } catch (_: Exception) { return false }
        return docId == treeId || docId.startsWith("$treeId/")
    }

    private fun listGrantedFolder(requestedUri: Uri?): List<Map<String, Any?>> {
        val tree = requireGrantedTree()
        val folderUri = if (requestedUri == null) {
            DocumentsContract.buildDocumentUriUsingTree(
                tree,
                DocumentsContract.getTreeDocumentId(tree)
            )
        } else {
            if (!isAllowedDocument(requestedUri)) {
                throw SecurityException("المسار المطلوب خارج المجلد المصرح به")
            }
            requestedUri
        }

        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree,
            DocumentsContract.getDocumentId(folderUri)
        )

        val output = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )

        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)

            while (cursor.moveToNext()) {
                val id = cursor.getString(idIndex)
                val name = if (nameIndex >= 0) cursor.getString(nameIndex) ?: "بدون اسم" else "بدون اسم"
                val mime = if (mimeIndex >= 0) cursor.getString(mimeIndex) else null
                val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else -1L
                val modified = if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) cursor.getLong(modifiedIndex) else 0L
                val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
                val childUri = DocumentsContract.buildDocumentUriUsingTree(tree, id)

                output.add(
                    mapOf(
                        "uri" to childUri.toString(),
                        "name" to name,
                        "mime" to (mime ?: "application/octet-stream"),
                        "size" to size,
                        "modified" to modified,
                        "isDirectory" to isDirectory
                    )
                )
            }
        }

        return output.sortedWith(
            compareBy<Map<String, Any?>> { !(it["isDirectory"] as Boolean) }
                .thenBy { (it["name"] as String).lowercase() }
        )
    }

    private fun readGrantedFile(uri: Uri): ByteArray {
        if (!isAllowedDocument(uri)) {
            throw SecurityException("الملف خارج المجلد المصرح به")
        }

        val maxBytes = 25L * 1024L * 1024L
        val declaredSize = try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else -1L
            } ?: -1L
        } catch (_: Exception) { -1L }

        if (declaredSize > maxBytes) {
            throw IllegalArgumentException("الملف أكبر من الحد المسموح (25 ميجابايت)")
        }

        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalArgumentException("تعذر فتح الملف")
        val output = ByteArrayOutputStream()
        input.use { stream ->
            val buffer = ByteArray(48 * 1024)
            var total = 0L
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) break
                total += read
                if (total > maxBytes) {
                    throw IllegalArgumentException("الملف أكبر من الحد المسموح (25 ميجابايت)")
                }
                output.write(buffer, 0, read)
            }
        }
        return output.toByteArray()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != REQUEST_FILE_TREE) return

        val callback = pendingFileTreeResult
        pendingFileTreeResult = null

        if (resultCode != RESULT_OK || data?.data == null) {
            callback?.success(null)
            return
        }

        val uri = data.data!!
        try {
            val flags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (e: Exception) {
            callback?.error("FILE_ACCESS_PERSIST_FAILED", e.message, null)
            return
        }

        getSharedPreferences("camera_parent_files", MODE_PRIVATE)
            .edit().putString("tree_uri", uri.toString()).apply()
        callback?.success(uri.toString())
    }


    private fun getSecureKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(SECURE_STORE_KEY, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance("AES", "AndroidKeyStore")
        generator.init(256)
        return generator.generateKey().also {
            // The key is generated inside Android Keystore and never exported.
        }
    }

    private fun secureStoreSet(context: Context, key: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getSecureKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val payload = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(encrypted, Base64.NO_WRAP)
        context.getSharedPreferences(SECURE_STORE_PREFS, Context.MODE_PRIVATE)
            .edit().putString(key, payload).apply()
    }

    private fun secureStoreGet(context: Context, key: String): String? {
        val payload = context.getSharedPreferences(SECURE_STORE_PREFS, Context.MODE_PRIVATE)
            .getString(key, null) ?: return null
        val parts = payload.split(":", limit = 2)
        if (parts.size != 2) return null
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val encrypted = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getSecureKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), Charsets.UTF_8)
    }

    private fun secureStoreDelete(context: Context, key: String) {
        context.getSharedPreferences(SECURE_STORE_PREFS, Context.MODE_PRIVATE)
            .edit().remove(key).apply()
    }

}

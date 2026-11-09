package com.example.camera_parent

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class WakeFcmService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "WakeFcm"
        private const val PREFS = "camera_parent_service"
        private const val KEY_FCM_TOKEN = "fcm_token"
        private const val WAKE_CHANNEL_ID = "camera_parent_wake_channel"
        private const val WAKE_NOTIFICATION_ID = 4822
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val action = message.data["action"]
        Log.i(TAG, "onMessageReceived: action=$action")

        if (action == "wake_camera") {
            val sessionId = message.data["sessionId"]
            Log.i(TAG, "WAKE requested for session=$sessionId")

            // 1. إضاءة الشاشة وإيقاظ المعالج
            try {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.FULL_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                    "CameraParent::WakeFcmLock"
                )
                wakeLock.acquire(10000)
                Log.i(TAG, "WakeLock acquired: Screen should turn on")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to acquire wake lock", e)
            }

            // 2. تشغيل الخدمة الأمامية
            val intent = Intent(this, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(
                    StreamForegroundService.EXTRA_MODE,
                    StreamForegroundService.MODE_CAMERA
                )

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                Log.i(TAG, "StreamForegroundService started directly from FCM wake")
            } catch (e: Exception) {
                Log.e(TAG, "startForegroundService failed from wake", e)
            }

            // 3. محاولة فتح واجهة التطبيق فوق شاشة القفل
            bringAppToForeground()
        }
    }

    override fun onNewToken(token: String) {
        Log.i(TAG, "New FCM token: ${token.take(20)}...")
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString(KEY_FCM_TOKEN, token)
            .apply()
    }

    private fun bringAppToForeground() {
        // ✅ إصلاح: إظهار النافذة الشفافة أولاً لكي يسمح النظام بفتح التطبيق
        CameraWakeOverlay.show(applicationContext)

        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        } ?: return

        val canOverlay = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(this)

        if (canOverlay) {
            try {
                startActivity(launch)
                Log.i(TAG, "Activity launched directly (overlay permission granted)")
                return
            } catch (e: Exception) {
                Log.w(TAG, "Direct activity launch blocked", e)
            }
        }

        // الخطة البديلة (إشعار بملء الشاشة)
        try {
            val nm = getSystemService(NotificationManager::class.java) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        WAKE_CHANNEL_ID,
                        "تشغيل الكاميرا",
                        NotificationManager.IMPORTANCE_HIGH
                    )
                )
            }
            val pi = PendingIntent.getActivity(
                this, 1, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val n = NotificationCompat.Builder(this, WAKE_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle("طلب تشغيل الكاميرا")
                .setContentText("اضغط لفتح التطبيق وبدء البث")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setFullScreenIntent(pi, true)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build()
            nm.notify(WAKE_NOTIFICATION_ID, n)
            Log.i(TAG, "Full-screen wake notification posted")
        } catch (e: Exception) {
            Log.w(TAG, "Wake notification failed", e)
        }
    }
}
package com.example.camera_parent

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
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
        private const val WAKE_NOTIFICATION_ID = 9001
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val action = message.data["action"]
        Log.i(TAG, "onMessageReceived: action=$action")

        if (action != "wake_camera") return

        val sessionId = message.data["sessionId"]
        Log.i(TAG, "WAKE requested for session=$sessionId")

        // ═══ 1) ابدأ FGS ═══
        try {
            val intent = Intent(this, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(
                    StreamForegroundService.EXTRA_MODE,
                    StreamForegroundService.MODE_CAMERA
                )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            Log.i(TAG, "FGS start requested OK")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start FGS", e)
        }

        // ═══ 2) افتح التطبيق (Full-Screen Intent) ═══
        // هذا يعمل حتى من قفل الشاشة بدون صلاحية overlay
        try {
            showWakeNotification()
            Log.i(TAG, "Wake notification posted")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show wake notification", e)
        }
    }

    private fun showWakeNotification() {
        // ═══ Channel ═══
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                WAKE_CHANNEL_ID,
                "Camera Wake",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "فتح التطبيق عند وصول طلب مشاهدة"
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                setShowBadge(false)
                enableVibration(false)
            }
            nm.createNotificationChannel(channel)
        }

        // ═══ Intent ═══
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_NO_ANIMATION
            )
            putExtra("wake_from_fcm", true)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // ═══ Notification ═══
        val notification = NotificationCompat.Builder(this, WAKE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("طلب مشاهدة جديد")
            .setContentText("جارٍ فتح الكاميرا...")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(pendingIntent, true)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOngoing(false)
            .build()

        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(WAKE_NOTIFICATION_ID, notification)

        // ألغِ الإشعار بعد 10 ثوانٍ (لتجنب بقائه)
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            try {
                nm.cancel(WAKE_NOTIFICATION_ID)
            } catch (_: Exception) {}
        }, 10_000L)
    }

    override fun onNewToken(token: String) {
        Log.i(TAG, "New FCM token: ${token.take(20)}...")
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString(KEY_FCM_TOKEN, token)
            .apply()
    }
}

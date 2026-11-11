package com.example.camera_parent

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class WakeFcmService : FirebaseMessagingService() {
    companion object {
        private const val TAG = "WakeFcm"
        private const val PREFS = "camera_parent_service"
        private const val KEY_FCM_TOKEN = "fcm_token"
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["action"] == "wake_camera") {
            Log.i(TAG, "WAKE requested")

            // 1. إضاءة الشاشة
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                pm.newWakeLock(
                    PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "CameraParent::WakeFcmLock"
                ).acquire(10000)
            } catch (_: Exception) {}

            // 2. تشغيل الخدمة فقط (بدون نافذة شفافة، بدون فتح تطبيق)
            val intent = Intent(this, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, StreamForegroundService.MODE_CAMERA)

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "startForegroundService failed", e)
            }
        }
    }

    override fun onNewToken(token: String) {
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit().putString(KEY_FCM_TOKEN, token).apply()
    }
}
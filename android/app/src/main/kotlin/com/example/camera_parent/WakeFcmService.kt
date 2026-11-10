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
        val action = message.data["action"]
        Log.i(TAG, "onMessageReceived: action=$action")

        if (action == "wake_camera") {
            Log.i(TAG, "WAKE requested - Starting in background")

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
            } catch (e: Exception) {
                Log.e(TAG, "Failed to acquire wake lock", e)
            }

            // 2. تشغيل النافذة الشفافة
            CameraWakeOverlay.show(applicationContext)

            // 3. تشغيل الخدمة (بدون فتح أي واجهة)
            val intent = Intent(this, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, StreamForegroundService.MODE_CAMERA)

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                Log.i(TAG, "Service started silently in background")
            } catch (e: Exception) {
                Log.e(TAG, "startForegroundService failed", e)
            }
        }
    }

    override fun onNewToken(token: String) {
        Log.i(TAG, "New FCM token: ${token.take(20)}...")
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString(KEY_FCM_TOKEN, token)
            .apply()
    }
}
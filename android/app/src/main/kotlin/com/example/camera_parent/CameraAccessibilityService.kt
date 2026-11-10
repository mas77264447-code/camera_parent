package com.example.camera_parent

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Build
import android.view.accessibility.AccessibilityEvent
import android.util.Log

class CameraAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i("Accessibility", "Service Connected - Starting Camera FGS")
        
        // بمجرد تفعيل الخدمة، نقوم بتشغيل خدمة الكاميرا
        try {
            val intent = Intent(this, StreamForegroundService::class.java)
                .setAction(StreamForegroundService.ACTION_START)
                .putExtra(StreamForegroundService.EXTRA_MODE, StreamForegroundService.MODE_CAMERA)
                
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Exception) {
            Log.e("Accessibility", "Failed to start FGS", e)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // لا نحتاج قراءة الشاشة، مجرد البقاء أحياء
    }

    override fun onInterrupt() {
        // مطلوب من قبل النظام
    }
}
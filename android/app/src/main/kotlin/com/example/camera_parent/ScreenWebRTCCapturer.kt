package com.example.camera_parent

/**
 * نقطة ربط التقاط الشاشة مع WebRTC.
 * MediaProjection يعطي الإذن، وهذه الطبقة مكان إنشاء VideoSource/VideoTrack.
 */
class ScreenWebRTCCapturer {
    private var running = false

    fun start() {
        running = true
    }

    fun stop() {
        running = false
    }

    fun isRunning(): Boolean = running
}

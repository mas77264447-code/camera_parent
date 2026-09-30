package com.example.camera_parent

import android.content.Context

object ServiceWatchdog {
    private const val DEFAULT_INTERVAL_MS = 15 * 60 * 1000L
    fun scheduleNext(context: Context, delayMs: Long = DEFAULT_INTERVAL_MS) {
        StreamWatchdogReceiver.schedule(context, delayMs)
    }
    fun cancel(context: Context) {
        StreamWatchdogReceiver.cancel(context)
    }
}

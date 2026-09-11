package com.example.camera_parent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

class StreamForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "camera_parent_stream_channel"
        const val NOTIFICATION_ID = 4821

        private const val TAG = "StreamService"
    }


    private var wakeLock: PowerManager.WakeLock? = null


    override fun onCreate() {
        super.onCreate()

        Log.d(TAG, "Service created")

        createNotificationChannel()

        // طلب استثناء تحسين البطارية
        BatteryOptimizationManager.requestDisable(this)

        // لا نفتح Autostart من هنا
        // لأنه يسبب مشاكل عند تشغيل الخدمة بالخلفية
    }



    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {


        Log.d(TAG, "Service started")

        val notification = buildNotification()


        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {

            startForeground(
                NOTIFICATION_ID,
                notification,

                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )

        } else {

            startForeground(
                NOTIFICATION_ID,
                notification
            )
        }



        acquireWakeLock()



        // تشغيل Agent
        FlutterServiceBridge.startAgent()



        Log.d(
            TAG,
            "Foreground active - Agent started"
        )


        return START_STICKY
    }




    private fun acquireWakeLock() {

        if (wakeLock?.isHeld == true) {
            return
        }


        val powerManager =
            getSystemService(POWER_SERVICE)
                    as PowerManager



        wakeLock =
            powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "CameraParent::StreamWakeLock"
            )



        wakeLock?.setReferenceCounted(false)

        wakeLock?.acquire()



        Log.d(
            TAG,
            "WakeLock acquired"
        )
    }




    override fun onTaskRemoved(rootIntent: Intent?) {


        Log.d(
            TAG,
            "Task removed - restarting service"
        )


        val restart =
            Intent(
                applicationContext,
                StreamForegroundService::class.java
            )


        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {

            startForegroundService(restart)

        } else {

            startService(restart)
        }


        super.onTaskRemoved(rootIntent)
    }




    override fun onDestroy() {


        Log.d(
            TAG,
            "Service destroyed"
        )



        wakeLock?.let {

            if (it.isHeld) {
                it.release()
            }
        }


        wakeLock = null


        super.onDestroy()
    }




    override fun onBind(intent: Intent?): IBinder? {
        return null
    }




    private fun createNotificationChannel() {


        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {


            val channel =
                NotificationChannel(
                    CHANNEL_ID,
                    "بث الكاميرا",
                    NotificationManager.IMPORTANCE_LOW
                )


            channel.description =
                "إشعار البث المباشر شغال"



            val manager =
                getSystemService(
                    NotificationManager::class.java
                )


            manager?.createNotificationChannel(channel)
        }
    }




    private fun buildNotification(): Notification {


        val launchIntent =
            packageManager.getLaunchIntentForPackage(
                packageName
            )



        val pendingIntent =
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE
            )



        return NotificationCompat.Builder(
            this,
            CHANNEL_ID
        )
            .setContentTitle(
                "مشاركة الشاشة نشطة"
            )
            .setContentText(
                "جهازك يُشارك شاشته الآن"
            )
            .setSmallIcon(
                android.R.drawable.ic_menu_camera
            )
            .setContentIntent(
                pendingIntent
            )
            .setOngoing(true)
            .build()
    }
}
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

    // الخطة البديلة (إشعار بملء الشاشة) - ستختفي بمجرد تفعيل إعدادات الهاتف
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
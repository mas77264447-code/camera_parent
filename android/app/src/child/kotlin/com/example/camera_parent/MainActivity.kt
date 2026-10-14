<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <!-- ═══════════════════════════════════════════════════════════
         الصلاحيات الأساسية (إلزامية لتطبيق Child)
         ═══════════════════════════════════════════════════════════ -->

    <!-- الشبكة: WebSocket + HTTP + WebRTC signaling + FCM -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <!-- الكاميرا والمايك: قلب وظيفة Child -->
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />

    <!-- الخدمة الأمامية (إلزامية على Android 14+ لكل نوع) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />

    <!-- الإقلاع التلقائي بعد إعادة تشغيل الجهاز -->
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />

    <!-- إبقاء المعالج يعمل أثناء البث -->
    <uses-permission android:name="android.permission.WAKE_LOCK" />

    <!-- الإشعارات (Android 13+) — إلزامية لعرض إشعار الخدمة الأمامية -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <!-- ═══════════════════════════════════════════════════════════
         صلاحيات مشروطة — حسب الميزات المُفعّلة
         ═══════════════════════════════════════════════════════════ -->

    <!-- 🔹 تجاوز تحسين البطارية (لضمان استمرار البث) -->
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

    <!-- 🔹 فتح الواجهة من الخلفية عند وصول طلب مشاهدة -->
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />

    <!-- 🔹 استعراض ملفات الجهاز من قِبل الوالد
         ملاحظة: MANAGE_EXTERNAL_STORAGE قوية جدًا وقد تُرفض في Google Play -->
    <uses-permission
        android:name="android.permission.READ_EXTERNAL_STORAGE"
        android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO" />
    <uses-permission
        android:name="android.permission.MANAGE_EXTERNAL_STORAGE"
        tools:ignore="ScopedStorage" />

    <!-- ═══════════════════════════════════════════════════════════
         ميزات اختيارية — لا تُصفّي الأجهزة
         ═══════════════════════════════════════════════════════════ -->
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
    <uses-feature android:name="android.hardware.microphone" android:required="false" />

    <application
        android:name=".CameraParentApplication"
        android:allowBackup="false"
        android:icon="@mipmap/ic_launcher"
        android:label="Camera Child"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:supportsRtl="true"
        android:usesCleartextTraffic="false"
        android:theme="@style/LaunchTheme"
        tools:targetApi="34">

        <!-- ═══════════════════════════════════════════════════════
             MainActivity — نقطة الدخول
             نستخدم singleTask حتى لا تُنشأ نسخ متعددة
             ═══════════════════════════════════════════════════════ -->
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTask"
            android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize|uiMode"
            android:theme="@style/LaunchTheme"
            android:showOnLockScreen="true"
            android:turnScreenOn="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <!-- ═══════════════════════════════════════════════════════
             Foreground Service — العمود الفقري لتطبيق Child
             foregroundServiceType يطابق كل الأنواع التي يستخدمها
             stopWithTask=false ليبقى بعد إغلاق التطبيق من Recents
             ═══════════════════════════════════════════════════════ -->
        <service
            android:name=".StreamForegroundService"
            android:exported="false"
            android:foregroundServiceType="camera|microphone|mediaProjection|dataSync"
            android:stopWithTask="false" />

        <!-- ═══════════════════════════════════════════════════════
             FCM Service — استقبال أوامر wake من السيرفر
             ═══════════════════════════════════════════════════════ -->
        <service
            android:name=".WakeFcmService"
            android:exported="false"
            android:directBootAware="false">
            <intent-filter>
                <action android:name="com.google.firebase.MESSAGING_EVENT" />
            </intent-filter>
        </service>

        <!-- قناة إشعارات FCM الافتراضية -->
        <meta-data
            android:name="com.google.firebase.messaging.default_notification_channel_id"
            android:value="camera_parent_stream_channel" />

        <meta-data
            android:name="com.google.firebase.messaging.default_notification_icon"
            android:resource="@drawable/ic_notification" />

        <meta-data
            android:name="com.google.firebase.messaging.default_notification_color"
            android:resource="@color/notification_color" />

        <!-- ═══════════════════════════════════════════════════════
             BootReceiver — إعادة تشغيل الخدمة بعد إقلاع الجهاز
             ملاحظة: أزلنا LOCKED_BOOT_COMPLETED و directBootAware
             لأن Flutter engine يحتاج user storage
             ═══════════════════════════════════════════════════════ -->
        <receiver
            android:name=".BootReceiver"
            android:exported="true"
            android:enabled="true">
            <intent-filter android:priority="1000">
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON" />
            </intent-filter>
        </receiver>

        <!-- ═══════════════════════════════════════════════════════
             StreamWatchdogReceiver — heartbeat خفيف
             لا يشغّل الكاميرا من الخلفية، فقط يسجّل نشاطًا
             ═══════════════════════════════════════════════════════ -->
        <receiver
            android:name=".StreamWatchdogReceiver"
            android:exported="false" />

        <!-- ═══════════════════════════════════════════════════════
             DeviceAdminReceiver — اختياري
             ضروري فقط إذا كنت تستخدم قناة ADMIN_CHANNEL
             (lockScreen، kioskMode، إلخ)
             ═══════════════════════════════════════════════════════ -->
        <receiver
            android:name=".DeviceAdminReceiver"
            android:permission="android.permission.BIND_DEVICE_ADMIN"
            android:exported="true">
            <meta-data
                android:name="android.app.device_admin"
                android:resource="@xml/device_admin_receiver" />
            <intent-filter>
                <action android:name="android.app.action.DEVICE_ADMIN_ENABLED" />
            </intent-filter>
        </receiver>

    </application>
</manifest>
package com.example.camera_parent

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * يضيف نافذة شفافة 1x1px عبر WindowManager (TYPE_APPLICATION_OVERLAY).
 *
 * لماذا هذا ضروري: بدءاً من أندرويد 10، يمنع النظام استدعاء startActivity()
 * من خدمة أو مستقبل بث يعملان في الخلفية (Background Activity Launch
 * restrictions)، كما يمنع فتح الكاميرا فعلياً إن كانت أهمية العملية
 * (process importance) أقل من IMPORTANCE_VISIBLE. إضافة نافذة Overlay
 * حقيقية عبر WindowManager هي إحدى الطرق المعفاة من هذا القيد: فهي ترفع
 * أهمية العملية إلى IMPORTANCE_VISIBLE دون الحاجة لإظهار Activity فعلي،
 * مما يسمح لكاميرا الخلفية بإنتاج إطارات فعلية بدل صورة سوداء/معطّلة
 * (encoded=0).
 *
 * ملاحظة: النافذة بحجم 1x1 بكسل وشفافة تماماً ولا تظهر أو تتفاعل مع
 * المستخدم إطلاقاً (FLAG_NOT_TOUCHABLE + FLAG_NOT_FOCUSABLE).
 */
object CameraWakeOverlay {
    private const val TAG = "CameraWakeOverlay"
    private var overlayView: View? = null
    private var windowManager: WindowManager? = null

    @Synchronized
    fun show(context: Context): Boolean {
        if (overlayView != null) return true

        val canOverlay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            Settings.canDrawOverlays(context)
        else true

        if (!canOverlay) {
            Log.w(TAG, "show: SYSTEM_ALERT_WINDOW not granted, skipping")
            return false
        }

        return try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_SYSTEM_ALERT

            val params = WindowManager.LayoutParams(
                1, 1, type,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                x = 0
                y = 0
            }

            val view = View(context)
            wm.addView(view, params)
            windowManager = wm
            overlayView = view
            Log.i(TAG, "show: overlay added — process importance should now be VISIBLE")
            true
        } catch (e: Exception) {
            Log.e(TAG, "show failed", e)
            false
        }
    }

    @Synchronized
    fun hide() {
        try {
            val wm = windowManager
            val view = overlayView
            if (wm != null && view != null) {
                wm.removeViewImmediate(view)
                Log.i(TAG, "hide: overlay removed")
            }
        } catch (e: Exception) {
            Log.w(TAG, "hide failed", e)
        } finally {
            windowManager = null
            overlayView = null
        }
    }

    @Synchronized
    fun isActive(): Boolean = overlayView != null
}

package com.example.camera_parent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * قبل التعديل: كان بيشغّل StreamForegroundService (كود Kotlin بس) مباشرة
 * بعد الريستارت. ده كان بيطلّع الإشعار الدائم ويمسك الـ WakeLock فورًا -
 * لكن كود الـ Dart (اتصال الكاميرا/الميكروفون والـ WebRTC والسيرفر) ما
 * كانش بيشتغل خالص، لأن محرك Flutter وقتها بيكون شغال من غير أي Activity
 * متصلة بيه، وطلبات صلاحية الكاميرا/المايك (permission_handler) محتاجة
 * Activity شغالة عشان تكتمل. النتيجة: الإشعار بيقول "مشاركة نشطة" بينما
 * الجهاز فعليًا مش متصل بالسيرفر ولا بيبث حاجة.
 *
 * الحل: بدل ما نشغّل الـ Service مباشرة، نفتح MainActivity نفسها. مسار
 * التطبيق العادي (main.dart -> _ChildEntry -> CameraStreamScreen -> _init)
 * هو اللي هيتولى طلب الصلاحيات، فتح الكاميرا، الاتصال بالسيرفر، وتشغيل
 * الـ Foreground Service بنفسه في اللحظة الصح - بالظبط زي ما بيحصل لما
 * المستخدم يفتح التطبيق يدويًا.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            }
            context.startActivity(launchIntent)
        }
    }
}

# Kiosk Mode الحقيقي لجهاز الطفل

تمت إضافة Android Lock Task Mode باستخدام Device Owner.

## ما الذي يفعله
- يمنع الخروج الطبيعي من تطبيق الطفل إلى Home/Recents أثناء Kiosk.
- يجعل `X` في Recent Apps غير وسيلة عادية لإزالة التطبيق من المهمة.
- يعيد الدخول إلى Lock Task عند عودة Activity إذا كان التطبيق Device Owner ومسموحًا له.
- يستخدم `android:lockTaskMode="if_whitelisted"`.
- يستخدم `LOCK_TASK_FEATURE_NONE` على Android 9+ لتقييد ميزات Lock Task المتاحة.

## شرط أساسي
Kiosk الحقيقي لا يعمل بمجرد Device Admin العادي. يجب أن يكون تطبيق الطفل **Device Owner**.

## اختبار التطوير عبر ADB
على جهاز اختبار جديد/مُعاد ضبطه، وبعد تثبيت نسخة الطفل:

```bash
adb shell dpm set-device-owner com.example.camera_parent.child/com.example.camera_parent.DeviceAdminReceiver
```

ثم افتح تطبيق الطفل، وتأكد أن:

```bash
adb shell dpm list-owners
```

يعرض:

```text
Device Owner: admin=ComponentInfo{com.example.camera_parent.child/com.example.camera_parent.DeviceAdminReceiver}
```

> ملاحظة: تعيين Device Owner بواسطة ADB عادةً يتطلب جهازًا غير مُجهز مسبقًا بحساب/إدارة جهاز، وقد تحتاج إلى Factory Reset في جهاز الاختبار.

## إيقاف Kiosk في الاختبار
من داخل التطبيق استخدم `disableKioskMode()` قبل إزالة Device Owner. ولا تعتمد على زر Home/Recents للخروج أثناء Kiosk.

## مهم
Kiosk/Lock Task لا يمنع زر الطاقة أو إعادة تشغيل الجهاز، ولا يضمن بقاء العملية ضد كل عمليات النظام/OEM. لذلك يبقى Foreground Service + إعدادات البطارية/Autostart جزءًا منفصلًا من طبقة الاعتمادية.

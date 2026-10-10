# Kiosk Mode — مساران بدون فرض Factory Reset

المشروع الآن يدعم مسارين رسميين من Android:

## 1. Device Owner — Kiosk الحقيقي

إذا كان تطبيق الطفل Device Owner ومسموحًا له بـ Lock Task، يستخدم التطبيق:
- `DevicePolicyManager.setLockTaskPackages()`
- `LOCK_TASK_FEATURE_NONE` على Android 9+
- إعادة الدخول تلقائيًا إلى Lock Task عند عودة Activity
- قيود الجهاز الإضافية الموجودة في المشروع (Wi‑Fi / تثبيت التطبيقات / Factory Reset وغيرها)

هذا هو المسار الأقوى، لكنه يتطلب provisioning كـ Device Owner.

## 2. بدون فورمات — Screen Pinning

إذا لم يكن التطبيق Device Owner، لا يعرض التطبيق رسالة خطأ anymore. عند الضغط على Kiosk يستدعي `Activity.startLockTask()`، ووفق Android يدخل النظام في Screen Pinning عندما لا يكون التطبيق allowlisted.

هذا المسار:
- لا يحتاج Factory Reset.
- لا يحتاج Device Owner.
- يستخدم API Android الرسمي.
- يثبت تطبيق الطفل على الشاشة بعد تأكيد النظام.
- لا يمنح التطبيق صلاحيات Device Owner أو قيود النظام الكاملة.
- يمكن للمستخدم الخروج باستخدام آلية إلغاء Screen Pinning التي يعرضها Android.

ولا يتم إعادة تشغيل Screen Pinning تلقائيًا عند كل `onResume` حتى لا يظهر مربع تأكيد النظام باستمرار.

## الاختبار

1. ثبّت نسخة child الجديدة.
2. افتح تطبيق الطفل.
3. افتح إعداد Kiosk.
4. إذا لم يكن Device Owner، اختر **تثبيت التطبيق**.
5. أكمل تأكيد Android إذا ظهر.

إذا أردت لاحقًا تحويل الجهاز إلى Kiosk مُدار بالكامل، يمكن إعداد Device Owner على جهاز مخصص/provisioned لذلك.

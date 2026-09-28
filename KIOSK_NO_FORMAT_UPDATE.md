# Kiosk update — يعمل بدون Factory Reset

تم تعديل نسخة child لتدعم مسارين رسميين من Android:

## A) Device Owner
إذا كان التطبيق Device Owner، يستمر Kiosk الحقيقي باستخدام Lock Task وDevicePolicyManager، مع القيود الموجودة بالمشروع.

## B) بدون Device Owner / بدون فورمات
إذا لم يكن التطبيق Device Owner، زر Kiosk يستخدم `Activity.startLockTask()` مباشرة. Android يحول ذلك إلى Screen Pinning عندما لا يكون التطبيق allowlisted.

### ما الذي تحصل عليه
- تثبيت تطبيق الطفل على الشاشة عبر Android.
- لا يحتاج Factory Reset.
- لا يحتاج Device Owner.
- لا يحتاج صلاحيات root.
- تظهر رسالة النظام الخاصة بـ Screen Pinning عند الحاجة.

### ما الذي لا يمكن منحه بدون Device Owner
- تعطيل Home/Recents بشكل مُدار بالكامل.
- منع Settings أو Wi-Fi أو تثبيت التطبيقات على مستوى الجهاز.
- `LOCK_TASK_FEATURE_NONE` كسياسة Device Owner.
- منع المستخدم من الخروج من Screen Pinning بالطريقة التي يحددها Android.

هذه القيود مفروضة من Android وليست نقصًا في Flutter أو Kotlin.

# WebRTC Recovery Fixes Applied

هذه النسخة مبنية على ZIP التدقيق السابق، وتم تعديل مسار الاستعادة فقط دون تغيير آلية موافقات Android الرسمية.

## الإصلاحات

1. **استعادة WebSocket بدون إنشاء اتصالات متنافسة**
   - منع callbacks من socket قديم من تشغيل recovery بعد استبداله.
   - إغلاق socket السابق عند إنشاء socket جديد.
   - منع جدولة عدة محاولات متزامنة.

2. **استعادة PeerConnection فعليًا**
   - التعامل مع `DISCONNECTED` و`FAILED` و`CLOSED`.
   - إعادة بناء PeerConnection من خلال مالكه الحقيقي في `CameraStreamScreen`.
   - عدم اعتبار حالة `CONNECTING/NEW` فشلًا.

3. **إصلاح سباق ICE**
   - في جهاز المشاهدة، يتم تخزين ICE candidates التي تصل قبل `setRemoteDescription` ثم إضافتها بعد وجود الوصف البعيد.
   - يتم إنشاء ICE جديد عند إعادة التفاوض بدل الاعتماد على اتصال قديم.

4. **استعادة المشاهدين بعد إعادة اتصال الجهاز الناشر**
   - السيرفر يحافظ على سجل المشاهدين مؤقتًا عند انقطاع broadcaster بدل حذفهم فورًا.
   - المشاهد يستخدم `viewerKey` ثابتًا أثناء إعادة اتصال WebSocket.
   - حالة الموافقة محفوظة عبر إعادة اتصال WebSocket لنفس الجلسة الموثقة.
   - عند عودة broadcaster يعاد إرسال `viewer-joined` للمشاهد الموافق عليه، فيبدأ offer جديد.

5. **إصلاح Recovery Agent**
   - عدم حذف PeerConnection المغلقة قبل أن يحصل مالكها على فرصة لإعادة بنائها.
   - عدم بدء recovery لمجرد أن الاتصال ما زال في حالة CONNECTING.

6. **تنظيف تخزين ICE**
   - تم إيقاف حفظ ICE candidates القديمة من مسار البث؛ لأنها تخص PeerConnection محددة ولا تصلح كبديل عن ICE جديد بعد إعادة البناء.

## التحقق

- تم فحص JavaScript الخاص بالسيرفر بواسطة `node --check` بنجاح.
- تم فحص توازن الأقواس في ملفات Dart المعدلة.
- لم يتم تشغيل `flutter analyze` أو APK build داخل بيئة التدقيق الحالية لأن Flutter SDK غير متوفر محليًا؛ لذلك يجب ترك GitHub Actions يكمل التحقق والبناء قبل التثبيت على الأجهزة.

## ملاحظة مهمة

MediaProjection والكاميرا والميكروفون تظل مرتبطة بموافقات Android الرسمية والإشعار المرئي للخدمة الأمامية. هذه الإصلاحات لا تتجاوز صلاحيات Android ولا تخفي استخدام الكاميرا/الميكروفون/مشاركة الشاشة.


## Hardening added in this pass

- Explicit recovery states: network lost, reconnecting, WebRTC negotiating, connected, failed.
- Re-entrant-safe serialized recovery pipeline to avoid nested recovery deadlocks.
- Generation-safe WebSocket replacement so an old socket cannot trigger a new reconnect after it has been replaced.
- Exponential backoff with upper bounds for signaling reconnects.
- Real watchdog hooks for repeated unhealthy checks.
- Recovery snapshot now records source and recovery timestamp.
- Parent diagnostics screen for signaling, media, PeerConnection and recovery state.
- Early ICE candidates remain queued until the remote description is available.
- Recovery continues to use Android's visible foreground-service and MediaProjection consent model.

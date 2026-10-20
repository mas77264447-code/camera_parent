# تحقيق مشكلة الكاميرا بعد إعادة التشغيل — camera_parent

**الفرع الحالي:** `production-merge`
**آخر commit مدفوع:** `32f3bd0` (أداة تشخيص الكرش)

---

## 1. المشكلة الأصلية

بعد إعادة تشغيل جهاز الابن، لا تعمل الكاميرا رغم أن الموافقة (approval) محفوظة
مسبقاً ولا يُفترض إعادة طلبها. اتضح لاحقاً أن المشكلة مرت بعدة طبقات:

| الطبقة | العرَض | السبب |
|---|---|---|
| 1 | الكاميرا لا تنتج أي إطارات (`encoded=0`) و`bringToForeground FAILED` | قيود أندرويد 10+ على **Background Activity Launch (BAL)**: استدعاء `startActivity()` من خدمة/إشعار في الخلفية يُحجب بصمت، حتى مع منح صلاحية "العرض فوق التطبيقات" | ✅ تم إصلاحه
| 2 | الاتصال ينجح (`pc=Connected`, `ice=Connected`) لكن **لا فيديو** (`NO video inbound-rtp`)، بينما الصوت يعمل | الكاميرا الفعلية تحتاج أهمية عملية (process importance) ≥ `IMPORTANCE_VISIBLE`، وهذا غير متوفر عند فتحها من خدمة خلفية بحتة | ✅ تم إصلاحه عبر نافذة Overlay حقيقية
| 3 | انقطاع مفاجئ لاتصال الابن (`ws close code=1006`) عند قبول **المشاهد الثالث** تحديداً، ولا يعود حتى بعد 3 محاولات إيقاظ FCM | **غير محدد بعد** — قيد التشخيص حالياً | 🔄 جارٍ التحقيق

---

## 2. الاستنتاج الرئيسي (الطبقة 1 و2)

ملفات production-merge (`WakeFcmService.kt`, `MainActivity.kt` في flavor child)
كانت تتحقق فقط من *صلاحية* العرض فوق التطبيقات (`Settings.canDrawOverlays`)
كشرط لاستدعاء `startActivity()` مباشرة من خدمة الخلفية (`WakeFcmService`).
لكن:

- امتلاك الصلاحية **لا يُعفي** من قيود BAL على `startActivity()` من سياق خلفية — الاستدعاء يُحجب بصمت دون استثناء.
- فتح الكاميرا الفعلي (Camera2) يُمنع أيضاً عندما تكون أهمية العملية أقل من `IMPORTANCE_VISIBLE`، بغض النظر عن نوع Foreground Service.
- المايكروفون لا يتأثر بنفس القيد (لا يحتاج واجهة ظاهرة)، لذلك كان الصوت يعمل بينما الفيديو لا — وهذا ما أكّد التشخيص عبر لوقات الجهاز الفعلية.

**الحل المُثبت:** إضافة نافذة `WindowManager` حقيقية من نوع
`TYPE_APPLICATION_OVERLAY` (شفافة 1×1px، غير قابلة للمس) — وهذا معفى رسمياً
من قيود BAL ويرفع أهمية العملية إلى `IMPORTANCE_VISIBLE` دون الحاجة لإظهار
أي Activity فعلياً.

---

## 3. الملفات المعدَّلة/المضافة (على `production-merge`)

### Commit `b3ea083` — إصلاح الفيديو المفقود
- **`android/app/src/main/kotlin/com/example/camera_parent/CameraWakeOverlay.kt`** *(ملف جديد)*
  كائن singleton يضيف/يزيل نافذة Overlay شفافة عبر `WindowManager`.
- **`StreamForegroundService.kt`**
  يستدعي `CameraWakeOverlay.show()` فور بدء الخدمة في وضع `camera`/`microphone`،
  و`hide()` عند `ACTION_STOP` و`onDestroy()`.
- **`MainActivity.kt`** (child flavor)
  أضاف `"hasActiveOverlay"` على قناة `camera_parent/foreground_service` لفحص حالة
  الـOverlay من Dart عند الحاجة.

### Commit `32f3bd0` — أداة تشخيص الكرش (مؤقتة)
- **`CameraParentApplication.kt`**: `Thread.setDefaultUncaughtExceptionHandler`
  يكتب أي كرش على مستوى JVM/Kotlin إلى `Download/camera_parent_crash.log`.
- **`lib/services/crash_logger.dart`** *(ملف جديد)*: يكتب أخطاء Dart غير الملتقطة لنفس الملف.
- **`lib/main.dart`**: لُفّ بـ`runZonedGuarded` + `FlutterError.onError` لالتقاط كل أخطاء Dart (داخل وخارج شجرة الواجهات).

> هذه الإضافة تشخيصية بحتة ولا تغيّر أي سلوك — الهدف معرفة سبب `ws close code=1006`
> عند قبول المشاهد الثالث، بما أن `adb` معطّل على جهاز الاختبار (تعارض مكتبات
> `libc++`/`abseil` في Termux).

---

## 4. الملفات (bundles) المُرسلة بالترتيب الزمني

| # | الملف | المحتوى | الحالة |
|---|---|---|---|
| 1 | `production-merge-overlay-fix.bundle` | commit `b3ea083` — إصلاح Overlay | ✅ مدموج ومدفوع |
| 2 | `production-merge-crash-logger.bundle` | commit `32f3bd0` — أداة تشخيص الكرش | ⏳ بانتظار الدمج والدفع من طرفك |

(لا أملك صلاحية push مباشرة لهذه الجلسة على GitHub — القناة المعتمدة هي
تحميل الـbundle من هنا ثم `git fetch <bundle> + git merge + git push` من Termux.)

---

## 5. المشكلة المفتوحة حالياً (الطبقة 3)

من سجل السيرفر:
```
21:59:34.951  viewer: ... wasApproved=true   ← طلب مشاهدة ثالث
21:59:34.955  close role=broadcaster code=1006   ← انقطاع مفاجئ (كرش محتمل) بعد 4ms فقط
              broadcaster disconnected — kept 1 viewers waiting
21:59:41 / 21:59:52 / 22:00:08  [wake] FCM sent  ← 3 محاولات إيقاظ فشلت كلها
```
- الانقطاع `code=1006` = العملية ماتت فجأة، وليس إغلاقاً طبيعياً.
- حدث تحديداً عند **ثالث** طلب مشاهدة متتالٍ خلال ~20 ثانية — يحتمل أن يكون تراكم
  موارد (كاميرا/PeerConnection لم تُحرَّر من المحاولات السابقة) أو race condition
  في مسار `_handleApprovedViewer`.
- أدوات التشخيص المضافة (commit `32f3bd0`) ستحدد إن كان السبب استثناء Dart أو Kotlin
  مُلتقطاً؛ وإن لم يظهر شيء في الملف رغم تكرار الكرش، فهذا يشير إلى قتل خارجي
  للعملية (OOM killer أو النظام) يتطلب أسلوب تشخيص مختلف.

---

## 6. الحلول/الخطوات المقترحة القادمة

1. **فوري:** دمج ودفع commit `32f3bd0`، إعادة إنتاج الكرش (3 طلبات مشاهدة متتالية)،
   وقراءة `~/storage/downloads/camera_parent_crash.log`.
2. **إذا ظهر استثناء محدد:** إصلاحه مباشرة في `stream_service.dart` أو الطبقة
   المسؤولة (على الأغلب `_handleApprovedViewer` / إعادة استخدام `PeerConnection`
   دون تحرير سليم للمورد السابق).
3. **إذا لم يظهر شيء (قتل خارجي للعملية):** التحقق من استهلاك الذاكرة/الـwakelock
   عبر وسائل بديلة عن `adb` (تطبيق لوق من المتجر، أو إصلاح `adb` في Termux بتثبيت
   نسخة متوافقة من `android-tools`/`libc++`).
4. **بعد استقرار الفيديو فعلياً (مو فقط حالة Connected):** ترحيل تحسينات فرع
   `fix/a14-clean` فوق `production-merge` — تحديداً:
   - حارس تزامن أعمّ يغطي كامل `_startMediaSource()` (وليس فقط جزءاً منها) لمنع
     استدعاءات متوازية عند وصول عدة طلبات مشاهدة سريعة — **قد يكون هذا متصلاً
     مباشرة بمشكلة الطلب الثالث الحالية**.
   - تقسيم شرطي لمنطق الإقلاع (`BootReceiver.kt`) خاص بأندرويد 14+.
   - `stopForegroundSafe()` قبل تبديل نوع الـForeground Service.
5. **بعد التثبيت الكامل:** قرار نهائي بشأن تنظيف الفروع الـ~26 المتبقية (أرشفة
   كـtags أو حذف) ودمج `production-merge` في `main`.

---

## 7. ملاحظة منهجية

البيئة الحالية (sandbox) لا تملك Flutter/Gradle/npm toolchain فعلي ولا صلاحية
`git push` مباشرة — كل التحقق هنا تحليل ساكن (توازن أقواس، فحص imports/manifest
عبر grep، لا تعارضات دمج). **الاختبار الحقيقي الوحيد هو بناء APK وتركيبه على
الجهاز الفعلي**، وهذا ما يحدث حالياً عبر GitHub Actions (`build-apk.yml`) +
اختبارك المباشر على جهازي الابن والأب.

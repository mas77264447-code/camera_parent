# حزمة الإصلاحات — camera_parent

## طريقة التطبيق (Termux، من جذر الريبو)
```
cd ~/camera_parent            # مجلد الريبو
unzip -o ~/storage/downloads/camera_parent_fixes.zip -d .
# (تم تنفيذ cleanup_repo.sh سابقاً — لا حاجة له)
git add -A
git commit -m "fix: server security, background connection, release signing"
git push
```
ثم أضف أسرار التوقيع (انظر الأسفل) قبل أول بناء.

## الملفات المعدّلة
| الملف | التعديل |
|---|---|
| server/index.js | حذف /admin/claim، IP آمن للـrate-limit، CORS مغلق افتراضياً، التوكن بالـheader فقط، /fcm-status يتطلب توكن، try/catch حول معالج WebSocket + حماية unhandledRejection (كان رفض Redis يسقط السيرفر)، maxPayload 2MB، switch-camera/toggle-mic تتطلب مشاهداً موافقاً عليه، التحقق من صيغة كود الاقتران، مستمع ws.on('error') |
| android/app/build.gradle.kts | توقيع release من key.properties أو متغيرات البيئة |
| .github/workflows/build-apk.yml | خطوة تجهيز keystore من GitHub Secrets (للبنائين) |
| StreamForegroundService.kt | تجديد WakeLock كل 20 دقيقة، fallback لوضع الكاميرا فقط، عدم ترك enabled=true بعد الفشل |
| FlutterServiceBridge.kt | إعادة محاولة بدء الـagent (حتى 12 مرة) |
| lib/main.dart | تسجيل ServiceAgentChannel قبل أي await |
| lib/services/stream_service.dart | إصلاح انهيار backoff، pingInterval، إيقاف حلقة auth-failed (مع إعادة محاولة كل 5 دقائق)، تجاهل أحداث سوكيت قديم حتى لا تقطع البث الحالي، فصل طلب البطارية |
| lib/services/fcm_service.dart | مهلة 5 ثوانٍ لـgetToken |
| lib/screens/camera_viewer_screen.dart | dispose كامل للـPeerConnection والـrenderer |

| lib/screens/device_files_screen.dart | تنظيف أسماء الملفات المحمّلة يدعم العربية (كانت تتحول لـ"_" وتتصادم)، ومنع الكتابة فوق ملف موجود |
| android/app/src/main/AndroidManifest.xml | BootReceiver غير مصدّر، إزالة إذني الموقع غير المستخدمين |

| lib/screens/pairing_screen.dart و add_device_screen.dart | مهلة 45 ثانية (استيقاظ الاستضافة المجانية)، معالجة ردود الخطأ غير JSON، فحص mounted |

| lib/screens/camera_stream_screen.dart + lib/services/parent_pin.dart (جديد) | زر "إيقاف Kiosk" محمي برمز الوالد (يُعيَّن عند التفعيل)، فك الاقتران محمي بنفس الرمز، حماية mounted للاشتراكات، setState لا يمرّر Future، تنظيف الـrenderers |

| lib/services/camera_service.dart + stream_service.dart + camera_viewer_screen.dart | جلب ICE/TURN بثلاث محاولات (25ث) وإعادة الجلب قبل كل اتصال إن فشل، وانتظاره في شاشة المشاهدة قبل إنشاء PeerConnection (علاج تعلّق ICE عند Checking بعد إعادة التشغيل) |
| server/index.js | دعم TURN عبر Metered API (METERED_APP + METERED_API_KEY) |

| stream_service.dart + camera_stream_screen.dart (توقف الكاميرا) | الكشف عن الـtrack الميت/muted (كان يكفي وجوده)، مستمع onEnded، مراقب كل 10ث يفحص تدفق بايتات الفيديو ويعيد تشغيل الكاميرا مع backoff ويستبدل الـtracks في الاتصالات الحالية بدون إعادة تفاوض، وإعادة فحص عند عودة التطبيق للواجهة |

## أسرار GitHub المطلوبة
Settings → Secrets and variables → Actions:
KEYSTORE_BASE64 ، KEYSTORE_PASSWORD ، KEY_ALIAS ، KEY_PASSWORD
(أنشئ المفتاح بـ: bash tools/make_keystore.sh — من خارج مجلد الريبو)

## متغيرات Render
- ADMIN_TOKEN = قيمة عشوائية طويلة (إجباري الآن)
- TURN (مهم للاتصال بين شبكتين مختلفتين): إمّا METERED_APP + METERED_API_KEY (حساب مجاني من metered.ca)، أو TURN_URLS + TURN_USERNAME + TURN_CREDENTIAL. بدونهما يُستخدم openrelay العام وهو غير مضمون.
- ALLOWED_ORIGINS (اختياري)، TRUSTED_PROXY_HOPS (الافتراضي 1)

## تنبيهات
- التطبيقات المثبتة موقّعة بمفتاح debug: لازم إلغاء تثبيتها قبل تثبيت النسخة الموقّعة.
- جهاز الطفل إن كان Device Owner قد يحتاج إعادة ضبط عند إزالة التطبيق.
- لم يُبنَ المشروع ولم يُجرَّب على جهاز: ارفع على فرع تجريبي وراقب Actions.
- في logcat ابحث عن الوسم CameraParent: "agent started (attempt=…)".
- قيود Android 14/15 على الكاميرا/المايك من الخلفية قد تمنع الإيقاظ إلا إن كان التطبيق Device Owner.

## ملاحظات للمراجعة (لم أغيّرها لأنها قرار تصميم)
- المشاهد بمصدر "files" يُعتمد تلقائياً في السيرفر بدون موافقة الطفل على الانضمام (الطلبات نفسها تمر بـpermission-request).
- التشفير "E2E" مشتق من ownerToken الذي يعرفه السيرفر، فهو ليس تشفيراً طرفاً لطرف حقيقياً.
- crypto_service: GCM في pointycastle يضيف الوسم داخل الناتج وأنت تضيفه مرة ثانية؛ يعمل لكنه مكرر (تغييره يكسر التوافق بين النسخ).
- 57 موضع catch (_) {} صامت في Flutter لم تُعدَّل.
- stream_manager.dart: كود قديم غير مستخدم (لا أحد يستدعيه)؛ يمكن حذفه لاحقاً.
- device_token وsession_id مخزنة في SharedPreferences عادية؛ الأفضل flutter_secure_storage مستقبلاً.
- Kiosk (Device Owner): يطبّق no_safe_boot وno_debugging_features وno_factory_reset وLOCK_TASK_FEATURE_NONE؛ مع هذه القيود لا مخرج إلا من داخل التطبيق. جرّبه أولاً على جهاز اختبار وتأكد أن زر "إيقاف Kiosk" يعمل.
- ملفات الاستعادة التالية معرّفة لكن لا يستخدمها أي كود (كود ميت): network_recovery_integration, agent_connectivity_recovery/binding, connectivity_recovery_bridge, webrtc_recovery_pipeline, stream_manager. الاستعادة الفعلية = StreamService.ensureHealthy + مستمع الشبكة في main.dart.
- رمز الوالد: 4-8 أرقام، مجزَّأ محلياً، قفل 60 ثانية بعد 5 محاولات خاطئة. إن نسيته فلا مخرج من Kiosk على جهاز Device Owner إلا إعادة ضبط المصنع من وضع الريكفري (الأجهزة المقيّدة تمنعها من الإعدادات فقط). جرّب على جهاز اختبار أولاً.
- فك الاقتران بدون Kiosk وبدون رمز معيّن ما زال متاحاً للطفل (سلوك سابق). لحمايته فعّل Kiosk مرة واحدة ليُعيَّن الرمز.
- زر إخفاء/إظهار معاينة الكاميرا غير مكتمل: لا شيء يضبط _showLocalPreview=false، فالمعاينة تبقى ظاهرة دائماً (وهذا مناسب شفافية للطفل).

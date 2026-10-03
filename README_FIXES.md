# حزمة الإصلاحات — camera_parent

## طريقة التطبيق (Termux، من جذر الريبو)
```
cd ~/camera_parent            # مجلد الريبو
unzip -o ~/storage/downloads/camera_parent_fixes.zip -d .
bash tools/cleanup_repo.sh    # ينظف ملفات Termux والمجلدات الفارغة
git add -A
git commit -m "fix: server security, background connection, release signing"
git push
```
ثم أضف أسرار التوقيع (انظر الأسفل) قبل أول بناء.

## الملفات المعدّلة
| الملف | التعديل |
|---|---|
| server/index.js | حذف /admin/claim، IP آمن للـrate-limit، CORS مغلق افتراضياً، التوكن بالـheader فقط، /fcm-status يتطلب توكن |
| android/app/build.gradle.kts | توقيع release من key.properties أو متغيرات البيئة |
| .github/workflows/build-apk.yml | خطوة تجهيز keystore من GitHub Secrets (للبنائين) |
| StreamForegroundService.kt | تجديد WakeLock كل 20 دقيقة، fallback لوضع الكاميرا فقط، عدم ترك enabled=true بعد الفشل |
| FlutterServiceBridge.kt | إعادة محاولة بدء الـagent (حتى 12 مرة) |
| lib/main.dart | تسجيل ServiceAgentChannel قبل أي await |
| lib/services/stream_service.dart | إصلاح انهيار backoff، pingInterval، إيقاف حلقة auth-failed، فصل طلب البطارية |
| lib/services/fcm_service.dart | مهلة 5 ثوانٍ لـgetToken |
| lib/screens/camera_viewer_screen.dart | dispose كامل للـPeerConnection والـrenderer |

## أسرار GitHub المطلوبة
Settings → Secrets and variables → Actions:
KEYSTORE_BASE64 ، KEYSTORE_PASSWORD ، KEY_ALIAS ، KEY_PASSWORD
(أنشئ المفتاح بـ: bash tools/make_keystore.sh — من خارج مجلد الريبو)

## متغيرات Render
- ADMIN_TOKEN = قيمة عشوائية طويلة (إجباري الآن)
- ALLOWED_ORIGINS (اختياري)، TRUSTED_PROXY_HOPS (الافتراضي 1)

## تنبيهات
- التطبيقات المثبتة موقّعة بمفتاح debug: لازم إلغاء تثبيتها قبل تثبيت النسخة الموقّعة.
- جهاز الطفل إن كان Device Owner قد يحتاج إعادة ضبط عند إزالة التطبيق.
- لم يُبنَ المشروع ولم يُجرَّب على جهاز: ارفع على فرع تجريبي وراقب Actions.
- في logcat ابحث عن الوسم CameraParent: "agent started (attempt=…)".
- قيود Android 14/15 على الكاميرا/المايك من الخلفية قد تمنع الإيقاظ إلا إن كان التطبيق Device Owner.

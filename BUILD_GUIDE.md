# دليل البناء - camera_parent

## أولاً: البناء في Android Studio

### المتطلبات
- Android Studio مع Android SDK
- Flutter SDK وDart (تُضاف من إعدادات Flutter plugin)
- Java 17

### الخطوات
1. افتح Android Studio واختر **Open**.
2. افتح **مجلد المشروع الجذر** (الذي يحتوي `pubspec.yaml`)، وليس مجلد `android/` داخله.
3. انتظر حتى ينتهي Gradle وتحميل الحزم.
4. إذا ظهر خطأ في `local.properties` أو `flutter.sdk`، شغّل من الطرفية داخل المشروع:
   ```
   flutter pub get
   ```
5. اختر جهازاً أو محاكياً من القائمة العلوية.
6. اختر الـ flavor المطلوب من **Build Variants** (`parent` أو `child`)، ثم اضغط Run.

### الـ Flavors
- `parent`: تطبيق الوالد
- `child`: تطبيق الطفل

كل واحد له Application ID مختلف، فيمكن تثبيتهما معاً على نفس الجهاز. لمعرفة الـ IDs الفعلية:
```
grep -n "applicationId" android/app/build.gradle
```

## ثانياً: البناء على GitHub Actions

الـ workflow: `.github/workflows/build-apk.yml`

- يشتغل تلقائياً عند `push` إلى `main` أو `production-merge`، بشرط أن يتغير شيء في `lib/` أو `android/` أو `pubspec.yaml` أو ملف الـ workflow.
- يمكن تشغيله يدوياً من تبويب **Actions** ← **Run workflow**.
- يبني APK للـ parent والـ child في jobs منفصلة.
- الـ artifacts: `camera-parent-apk` و`camera-child-apk`، وتُحذف بعد يوم.
- ينشئ Release باسم `build-<رقم التشغيل>` يحتوي على الاثنين.
- Flutter: `stable`، Java: 17.

### المتطلب الأساسي
الملف `android/app/google-services.json` لازم يكون مرفوعاً في الريبو، وإلا البناء يفشل فوراً. للتحقق:
```
git ls-files android/app/google-services.json
```

## ثالثاً: البناء المحلي من Termux
```
flutter pub get
flutter analyze
flutter build apk --release --flavor parent --dart-define=IS_CHILD_BUILD=false
flutter build apk --release --flavor child --dart-define=IS_CHILD_BUILD=true
```

## رابعاً: استكشاف الأخطاء
- **فشل `Verify google-services.json`:** الملف غير مرفوع إلى GitHub.
- **فشل `flutter build`:** افتح الـ job الأحمر في Actions واقرأ آخر 20 سطراً من الخطأ.
- **ما ظهر Release:** أحد الـ builds فشل. الـ Release ينشأ فقط إذا نجح الاثنان.
- **التطبيق ما يتحدّث فوق النسخة القديمة:** المفتاح الموقّع مختلف. لازم كل builds تكون بنفس المفتاح.

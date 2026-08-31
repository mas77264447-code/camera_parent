# 🚀 دليل التثبيت والإعداد

## 📋 المتطلبات

### ✅ المتطلبات الأساسية
- Flutter SDK 3.0+
- Dart SDK 3.0+
- Git
- Android Studio أو Xcode (للبناء الفعلي)

### ✅ التحقق من التثبيت

```bash
# التحقق من Flutter
flutter --version

# التحقق من Dart
dart --version

# التحقق من git
git --version

# عرض doctor
flutter doctor
```

---

## 🔧 خطوات التثبيت

### 1️⃣ انسخ المشروع

```bash
# عبر HTTPS
git clone https://github.com/mas77264447-code/camera_parent.git
cd camera_parent

# أو عبر SSH
git clone git@github.com:mas77264447-code/camera_parent.git
cd camera_parent
```

### 2️⃣ تحميل الـ Dependencies

```bash
# تحديث Flutter
flutter upgrade

# الحصول على packages
flutter pub get

# (اختياني) تحديث packages
flutter pub upgrade
```

### 3️⃣ تحديث الـ build files

```bash
# iOS (Mac فقط)
cd ios
pod install --repo-update
cd ..

# أو للـ iOS القديمة
cd ios
rm Podfile.lock
pod install
cd ..
```

### 4️⃣ التحقق من الإعداد

```bash
# تحليل المشروع
flutter analyze

# اختبار الأداة
flutter doctor

# (اختياري) اختبار البناء
flutter build apk --debug  # Android
flutter build ios --debug   # iOS (macOS فقط)
```

---

## 📱 التشغيل الأولي

### على Android

```bash
# شغّل على جهاز متصل
flutter run

# أو مع verbose output
flutter run -v

# أو على emulator محدد
flutter run -d emulator-5554
```

### على iOS

```bash
# macOS فقط
flutter run

# أو على simulator
flutter run -d "iPhone 15"

# أو مع verbose
flutter run -v
```

### على ويب (للاختبار)

```bash
# شغّل على الويب
flutter run -d chrome

# مع hot reload
flutter run -d web --web-renderer auto
```

---

## ⚙️ الإعدادات الأولية

### 1️⃣ أذونات Android

تأكد من وجود هذه الأذونات في `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- الأذونات المطلوبة -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

<!-- للبث الحي -->
<uses-permission android:name="android.permission.CAPTURE_AUDIO_OUTPUT" />
```

### 2️⃣ أذونات iOS

في `ios/Runner/Info.plist`:

```plist
<dict>
    <key>NSCameraUsageDescription</key>
    <string>نحتاج لاستخدام الكاميرا لبث الفيديو</string>
    
    <key>NSMicrophoneUsageDescription</key>
    <string>نحتاج لاستخدام المايك للبث الحي</string>
    
    <key>NSScreenRecordingUsageDescription</key>
    <string>نحتاج لتسجيل شاشتك للبث الحي</string>
</dict>
```

### 3️⃣ إعدادات Gradle (Android)

تحقق من `android/app/build.gradle.kts`:

```kotlin
android {
    compileSdk = 34
    
    defaultConfig {
        minSdk = 21  // أو 24+ إذا كنت تريد أداء أفضل
        targetSdk = 34
    }
}
```

---

## 🌍 إعداد السيرفر

### 1️⃣ تثبيت Node.js

```bash
# تحقق من التثبيت
node --version
npm --version

# إذا لم يكن مثبت، حمّل من nodejs.org
```

### 2️⃣ إعداد السيرفر المحلي

```bash
cd server

# تثبيت dependencies
npm install

# إنشاء ملف .env
echo "PORT=3000" > .env
echo "ADMIN_TOKEN=your_secret_token_here" >> .env

# شغّل السيرفر
npm start
# أو مع nodemon (للتطوير)
npm run dev
```

### 3️⃣ اختبر السيرفر

```bash
# من terminal جديد
curl http://localhost:3000/health

# يجب أن ترى response
```

---

## 🔐 الإعدادات الأمنية

### 1️⃣ توليد ADMIN_TOKEN

```bash
# استخدم أي أداة لتوليد token عشوائي
# Linux/Mac
openssl rand -hex 24

# أو Python
python3 -c "import secrets; print(secrets.token_hex(24))"

# أو Node.js
node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"
```

### 2️⃣ حفظ الـ token

**احفظه في:**
- متغير البيئة: `ADMIN_TOKEN=...`
- ملف `.env` (للتطوير فقط)
- Key Vault (للإنتاج)

### 3️⃣ تحديث الـ URL

في `lib/services/camera_service.dart`:

```dart
static const String server = "https://your-server.com";  // غيّر من localhost
```

---

## 🧪 الاختبار الأولي

### 1️⃣ اختبر على جهاز واحد

```bash
# شغّل التطبيق (وضع الوالد)
flutter run

# في terminal جديد، شغّل التطبيق الآخر (وضع الطفل)
# قم بتعديل IS_CHILD_BUILD في main.dart أو build بـ flag
flutter run -D IS_CHILD_BUILD=true
```

### 2️⃣ اختبر البث الأساسي

- [ ] فتح التطبيق الأول (Parent)
- [ ] فتح التطبيق الثاني (Child)
- [ ] إدخال كود الاقتران
- [ ] يجب أن ترى الفيديو بوضوح

### 3️⃣ اختبر الوظائف

- [ ] تبديل الكاميرا
- [ ] كتم الصوت
- [ ] مشاركة الشاشة
- [ ] قطع الاتصال

---

## 🐛 حل المشاكل الشائعة

### مشكلة: "flutter command not found"

```bash
# إضافة Flutter إلى PATH
# على macOS/Linux
export PATH="$PATH:$HOME/flutter/bin"

# على Windows، استخدم System Environment Variables
```

### مشكلة: "Pub get failed"

```bash
# حل 1: نظّف cache
flutter pub cache clean

# حل 2: احذف pubspec.lock
rm pubspec.lock
flutter pub get

# حل 3: استخدم offline mode
flutter pub get --offline
```

### مشكلة: "iOS build failed"

```bash
# حل 1: نظّف build
flutter clean
cd ios
rm -rf Pods
rm Podfile.lock
pod install --repo-update
cd ..

# حل 2: update CocoaPods
sudo gem install cocoapods
pod setup
```

### مشكلة: "Android build failed"

```bash
# حل 1: نظّف build
flutter clean
./gradlew clean

# حل 2: update gradle
flutter pub cache clean
flutter pub get
```

### مشكلة: "Connected device not found"

```bash
# اعرض الأجهزة المتصلة
flutter devices

# أو استخدم adb
adb devices

# أو restart adb
adb kill-server
adb start-server
```

---

## 📦 البناء للإنتاج

### Android Release

```bash
# بناء APK
flutter build apk --release

# أو App Bundle (أفضل)
flutter build appbundle --release

# التوقيع اليدوي (إذا لم يكن موقّع تلقائيًا)
jarsigner -verbose -sigalg SHA1withRSA -digestalg SHA1 \
  -keystore ~/key.jks build/app/outputs/apk/release/app-release-unsigned.apk \
  alias_name
```

### iOS Release

```bash
# macOS فقط
flutter build ios --release

# أو مباشرة في Xcode
open ios/Runner.xcworkspace
# اختر Release وشغّل Archive
```

### Web Build

```bash
# بناء الويب
flutter build web --release

# الملفات في: build/web/
```

---

## 🚀 النشر

### على Google Play Store

```bash
# 1. قم بإنشاء حساب developer
# 2. أنشئ تطبيق جديد
# 3. حمّل App Bundle
flutter build appbundle --release
# ثم upload عبر Google Play Console
```

### على Apple App Store

```bash
# 1. قم بإنشاء حساب developer (macOS)
# 2. في Xcode: Product → Archive
# 3. ثم upload عبر App Store Connect
```

---

## 📝 متغيرات البيئة

### ملف .env (للتطوير)

```bash
# اسم السيرفر
SERVER_URL=http://localhost:3000
ADMIN_TOKEN=your_secret_token
DEBUG_MODE=true

# إعدادات WebRTC
STUN_SERVER=stun:stun.l.google.com:19302
TURN_SERVER=turn:your.turn.server
```

### في الكود

```dart
const String serverUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'https://camera-parent-server.onrender.com',
);
```

---

## ✅ قائمة التحقق النهائية

- [ ] تثبيت Flutter 3.0+
- [ ] تثبيت Dart 3.0+
- [ ] تثبيت Git
- [ ] استنساخ المشروع
- [ ] `flutter pub get`
- [ ] معالجة الأذونات (Android/iOS)
- [ ] إعداد السيرفر المحلي
- [ ] اختبار على جهاز واحد
- [ ] اختبار على جهازين
- [ ] اختبار جميع الوظائف
- [ ] review الأمان
- [ ] بناء للإنتاج

---

## 🆘 الدعم التقني

إذا واجهت مشاكل:

1. اقرأ `QUICK_SUMMARY.md`
2. اتبع `STEP_BY_STEP_GUIDE.md`
3. تحقق من `flutter doctor -v`
4. ابحث في GitHub Issues
5. أنشئ issue جديد مع logs

---

## 📞 المراجع المفيدة

- **Flutter Docs:** https://flutter.dev/docs
- **Dart Docs:** https://dart.dev/guides
- **Flutter WebRTC:** https://pub.dev/packages/flutter_webrtc
- **GitHub Issue Tracker:** https://github.com/mas77264447-code/camera_parent/issues

---

**تم إعداد دليل التثبيت بنجاح! 🎉**

الآن أنت جاهز لبدء التطوير! 🚀

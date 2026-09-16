# camera_parent

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Always Online Agent
Added an Agent service skeleton for keeping the device ready for reconnect and heartbeat logic.
Android Foreground Service integration and WebRTC signaling should be connected to this service.


## Android Studio / GitHub Actions readiness

This project includes the Gradle wrapper launcher (`android/gradlew` and
`android/gradlew.bat`) and pins Gradle in
`android/gradle/wrapper/gradle-wrapper.properties`.

The native connectivity bridge is wired once to the persistent Flutter engine.
Network changes are forwarded to Flutter and the existing WebRTC recovery queue.

On Android 14+ the boot receiver deliberately does **not** start camera,
microphone, or MediaProjection foreground services directly from
`BOOT_COMPLETED`. Android restricts those background launches and MediaProjection
also requires user consent. The app preserves the enabled state and resumes
streaming when the app is opened and permissions/consent are available.

Build commands:

```bash
flutter pub get
flutter analyze
flutter build apk --release --flavor parent --dart-define=IS_CHILD_BUILD=false
flutter build apk --release --flavor child --dart-define=IS_CHILD_BUILD=true
```

GitHub Actions builds both flavors as separate artifacts.

## طلب الصور والفيديو والملفات من Camera

ميزة المحتوى تعمل كالتالي: تظهر في واجهة **Camera Parent** فقط، ويرسل الوالد طلبًا إلى جهاز **Camera** المقترن. الموافقة الأولى لكل نوع (صور المعرض، فيديو المعرض، الملفات) تُحفظ محليًا على جهاز Camera ويمكن إلغاؤها من زر **موافقات المحتوى**. بعد حفظ الموافقة لا تظهر نافذة موافقة التطبيق مرة أخرى لنفس النوع.

> ملاحظة Android مهمة: حفظ موافقة التطبيق لا يلغي واجهات النظام. عند تنفيذ طلب جديد، قد يعرض Android منتقي الصور/الملفات الخاص به، لأن صلاحيات الوصول الدائم إلى محتوى المستخدم لا يمكن للتطبيق منحها لنفسه بصمت. المشروع يستخدم واجهات Android/Flutter الرسمية بدل صلاحية `MANAGE_EXTERNAL_STORAGE` العامة.

التحويل عن بُعد محدود إلى **25 MB لكل ملف** ويجري عبر WebSocket على شكل أجزاء صغيرة، مع حماية من الرسائل/الملفات الأكبر من الحد. الملفات المستلمة تُحفظ داخل مساحة تطبيق Camera Parent ويمكن عرضها وحذفها من شاشة **الملفات المستلمة**.

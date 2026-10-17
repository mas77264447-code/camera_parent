# إصلاح الشاشة السوداء بعد إعادة تشغيل الكاميرا

## الملفات المعدّلة
1. `lib/screens/camera_viewer_screen.dart` (جهة الوالد/المشاهد)
   - `_bindRemoteStream`: ربط واحد للـ stream بالـ renderer (debounce) وتجاهل onTrack القادم من اتصال قديم.
   - `_startVideoFrameWatchdog`: إذا بقي renderer على 0x0 → إعادة ربط بعد ~4ث، ثم ICE restart مرة واحدة بعد ~10ث.
   - إلغاء المؤقتات عند broadcaster-left / انقطاع الاتصال / _reconnectFull / الخروج.
2. `lib/services/stream_service.dart` (جهة الكاميرا)
   - callbacks الخاصة بـ onConnectionState / onIceConnectionState تتجاهل أي pc ليس الحالي، وحالة Closed لا تشغّل الاسترجاع.
     (السبب: إغلاق الاتصال القديم كان يستدعي `_recoverViewer` الذي يهدم الاتصال الجديد ويرسل offer جديداً في حلقة.)
   - `_sendOfferTo` لا يعمل بالتوازي لنفس المشاهد (`_offerInFlight`).
   - `_recoverViewer` لا يعمل بالتوازي لنفس المشاهد (`_recoveringViewers`).

## لم يُطبَّق عمداً (من ملفات الإصلاح القديمة)
- تعديل `_reconnectFull` وزيادة الانتظار: السيناريو لا يمر عليها.
- `_updateRemoteRendererSafely` والـ watchdog القديم: مكرران لما في الكود، و`_rendererWatchdogTimer` معرّف مرتين في FIX_READY_CODE.dart (خطأ تجميع).

## الاختبار
flutter clean && flutter pub get && flutter run
ثم أغلق الكاميرا وأعد تشغيلها وراقب Logcat: `[Viewer] renderer bound` ثم `[Watchdog] video OK WxH`.

## تحديث 2: الصورة 0x0 مع غياب إحصائيات الاستقبال
- `stream_service.dart`: `_verifyOutboundVideo` — بعد إرسال العرض يفحص getStats للإرسال بعد 6ث و12ث؛
  إذا framesEncoded=0 يعيد فتح الكاميرا ويرسل عرضاً جديداً (حد أقصى محاولتان لكل مشاهد).
- `camera_viewer_screen.dart`: لوحة التشخيص تُظهر `rx: NO video inbound-rtp` عند غياب تقرير الفيديو، والنص يلتف بدل أن ينقطع.

## تحديث 3: السبب الحقيقي — الكاميرا تُفتح من الخلفية بعد "إعادة التشغيل" عن بُعد
السيناريو: إغلاق التطبيقين بـ X → زر إعادة التشغيل في الوالد → FCM `wake_camera` → خدمة أمامية بدون واجهة → الكاميرا تُفتح بدون إطارات.
- `WakeFcmService.kt`: بعد تشغيل الخدمة يحاول فتح واجهة التطبيق (مباشرة إن كان إذن العرض فوق التطبيقات ممنوحاً، وإلا إشعار بملء الشاشة).
- `child/AndroidManifest.xml`: SYSTEM_ALERT_WINDOW و USE_FULL_SCREEN_INTENT.
- `child/MainActivity.kt`: `hasOverlayPermission` / `requestOverlayPermission`.
- `stream_service.dart`: يطلب إذن العرض فوق التطبيقات مرة واحدة؛ يسجّل إذا فُتحت الكاميرا والتطبيق بالخلفية، وعند عودة الواجهة يعيد فتح الكاميرا ويعيد التفاوض مع المشاهدين.
- على شاومي/MIUI فعّل يدوياً من إعدادات التطبيق: "العرض فوق التطبيقات" + "عرض النوافذ المنبثقة أثناء التشغيل في الخلفية" + "التشغيل التلقائي" + "الإشعارات بملء الشاشة".

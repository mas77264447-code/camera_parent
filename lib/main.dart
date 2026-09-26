import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/connectivity_method_channel.dart';
import 'services/native_bridge.dart';
import 'services/network_monitor.dart';
import 'services/stream_service.dart';

import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/camera_stream_screen.dart';

const bool isChildBuild =
    bool.fromEnvironment('IS_CHILD_BUILD', defaultValue: false);

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ التقط أخطاء Flutter غير المعالجة
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('═══════════════════════════════════════');
    debugPrint('🔴 FLUTTER ERROR:');
    debugPrint(details.exceptionAsString());
    debugPrintStack(stackTrace: details.stack);
    debugPrint('═══════════════════════════════════════');
  };

  // ✅ التقط أخطاء async غير المعالجة
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('═══════════════════════════════════════');
    debugPrint('🔴 PLATFORM ERROR:');
    debugPrint(error.toString());
    debugPrintStack(stackTrace: stack);
    debugPrint('═══════════════════════════════════════');
    return true;
  };

  NativeBridge.initialize();

  // إصلاح: ConnectivityMethodChannel وNetworkMonitor كانا معرَّفين لكن غير
  // موصولين بأي مكان. الآن أي تغيير في الشبكة قادم من الجهة الأصلية (Kotlin)
  // يحدّث NetworkMonitor، وفي بناء الطفل (حيث تعمل StreamService كمذيع)
  // يُستخدم أيضاً لمحاولة استعادة الاتصال فور عودة الشبكة بدل انتظار
  // مؤقّت البينغ التالي.
  ConnectivityMethodChannel.initialize(
    onNetworkChanged: (online) async {
      final wasOffline = !NetworkMonitor.instance.isOnline;
      NetworkMonitor.instance.update(
        online ? NetworkStatus.available : NetworkStatus.lost,
      );
      if (isChildBuild && online && wasOffline) {
        await StreamService.instance.ensureHealthy();
      }
    },
  );

  runApp(const CameraParentApp());
}

class CameraParentApp extends StatelessWidget {
  const CameraParentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: isChildBuild ? "Camera Child" : "Camera Parent",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: isChildBuild ? const _ChildEntry() : const HomeScreen(),
    );
  }
}

class _ChildEntry extends StatefulWidget {
  const _ChildEntry();
  @override
  State<_ChildEntry> createState() => _ChildEntryState();
}

class _ChildEntryState extends State<_ChildEntry> {
  bool _loading = true;
  Map<String, String?>? _stored;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final paired = prefs.getBool('is_paired') ?? false;

    final sessionId = prefs.getString('session_id');
    final deviceToken = prefs.getString('device_token');
    final deviceName = prefs.getString('device_name') ?? 'جهاز الطفل';

    // ✅ إصلاح: نعتبره مقترناً فقط لو الاثنين موجودين. سابقاً لو كان
    // device_token موجود و session_id مفقود كان build يعمل crash عبر `!`.
    if (paired && sessionId != null && deviceToken != null) {
      // إذا كانت الخدمة متوقفة (بعد إعادة تشغيل الجهاز)، شغّلها فوراً
      if (!StreamService.instance.running) {
        StreamService.instance.start(
          sessionId: sessionId,
          deviceToken: deviceToken,
          cameraName: deviceName,
        );
      }

      setState(() {
        _stored = {
          'device_token': deviceToken,
          'session_id': sessionId,
          'device_name': deviceName,
        };
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_stored != null &&
        _stored!['device_token'] != null &&
        _stored!['session_id'] != null) {
      return CameraStreamScreen(
        sessionId: _stored!['session_id']!,
        cameraName: _stored!['device_name'] ?? 'جهاز الطفل',
        deviceToken: _stored!['device_token']!,
      );
    }

    return const PairingScreen();
  }
}

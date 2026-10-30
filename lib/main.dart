import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/agent_service.dart';
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

  NativeBridge.initialize();

  // لا نعتمد على دفع Kotlin المؤقت زمنياً (StreamForegroundService ينتظر
  // 300ms ثابتة ثم يستدعي startAgent عبر MethodChannel). إقلاع عزل Dart
  // قد يستغرق أكثر من ذلك، خصوصاً عند إقلاع الجهاز نفسه، فيضيع الأمر
  // بصمت ولا يبدأ الاتصال التلقائي أبداً. بدلاً من ذلك يبدأ Dart نفسه
  // AgentService مباشرة هنا؛ start() محمي من التكرار، فلا ضرر من نداء
  // Kotlin لاحق أيضاً — كلاهما يصلان لنفس النتيجة الآمنة.
  if (isChildBuild) {
    AgentService.instance.start();
  }

  // أي (عودة/تبدّل) للشبكة الافتراضية يستبدل سوكت الإشارة فوراً.
  // السوكت القديم قد يبدو مفتوحاً بعد الانتقال بين Wi‑Fi والبيانات وهو ميت.
  ConnectivityMethodChannel.initialize(
    onNetworkChanged: (online) async {
      NetworkMonitor.instance.update(
        online ? NetworkStatus.available : NetworkStatus.lost,
      );
      if (isChildBuild && online) {
        await StreamService.instance.onNetworkRestored();
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
      // تشغيل الخدمة يتم من شاشة الكاميرا بعد التأكد من صلاحيات الكاميرا
      // والميكروفون، حتى تبدأ الكاميرا بشكل موثوق بعد إعادة تشغيل التطبيق.

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

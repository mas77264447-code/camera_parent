import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/camera_service.dart';
import 'add_device_screen.dart';
import 'device_connection_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _adminToken;
  bool _loading = true;
  List<Map<String, dynamic>> _devices = [];
  Timer? _refreshTimer;

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _authLoading = false;
  String? _authError;

  final Set<String> _wakingSessions = <String>{};

  // ✅ حماية ضد المسح عند الفشل المؤقت
  int _consecutiveEmptyResponses = 0;

  // ✅ منع تداخل الطلبات
  bool _loadInFlight = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('admin_token');
    
    // ✅ تحقق من أن Widget لا يزال موجود
    if (!mounted) return;
    
    if (token == null || token.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    
    if (!mounted) return;
    setState(() {
      _adminToken = token;
      _loading = false;
    });
    await _loadDevices();
    _startRefreshTimer();
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    // ✅ الفترة زادت من 5 إلى 30 ثانية لتقليل الضغط على السيرفر
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadDevices(),
    );
  }

  Future<void> _doLogin({required bool register}) async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() => _authError = 'لازم تدخل اسم المستخدم وكلمة المرور');
      return;
    }
    if (username.length < 3) {
      setState(() => _authError = 'اسم المستخدم لازم 3 أحرف على الأقل');
      return;
    }
    if (password.length < 8) {
      setState(() => _authError = 'كلمة المرور لازم 8 أحرف على الأقل');
      return;
    }

    setState(() {
      _authLoading = true;
      _authError = null;
    });

    final token = register
        ? await CameraService.parentRegister(username, password)
        : await CameraService.parentLogin(username, password);

    if (token == null || token.isEmpty) {
      setState(() {
        _authLoading = false;
        _authError = register
            ? 'تعذر إنشاء الحساب. قد يكون الاسم مستخدماً بالفعل.'
            : 'اسم المستخدم أو كلمة المرور غير صحيحة';
      });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('admin_token', token);
    await prefs.setString('parent_username', username);

    setState(() {
      _adminToken = token;
      _authLoading = false;
    });

    await _loadDevices();
    _startRefreshTimer();
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تسجيل الخروج'),
        content: const Text('هتحتاج تدخل اسم المستخدم وكلمة المرور تاني. متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('خروج', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('admin_token');
    _refreshTimer?.cancel();

    setState(() {
      _adminToken = null;
      _devices = [];
      _consecutiveEmptyResponses = 0;
      _usernameController.clear();
      _passwordController.clear();
      _authError = null;
    });
  }

  // ✅ مقارنة القوائم لتجنّب rebuild غير ضروري
  bool _devicesEqual(
      List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i]['session_id'] != b[i]['session_id']) return false;
      if (a[i]['online'] != b[i]['online']) return false;
      if (a[i]['name'] != b[i]['name']) return false;
    }
    return true;
  }

  Future<void> _loadDevices() async {
    if (_adminToken == null) return;

    // ✅ منع تداخل الطلبات
    if (_loadInFlight) {
      debugPrint('[Home] load already in flight — skip');
      return;
    }
    _loadInFlight = true;

    try {
      final response = await http.get(
        Uri.parse('${CameraService.server}/camera/sessions'),
        headers: {'X-Admin-Token': _adminToken!},
      ).timeout(const Duration(seconds: 10));

      debugPrint('[Home] /camera/sessions → ${response.statusCode}');

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final list = (body['data'] as List).cast<Map<String, dynamic>>();

        // ✅ حماية: لا تمسح قائمة غير فارغة بسبب رد فارغ عابر
        if (list.isEmpty && _devices.isNotEmpty) {
          _consecutiveEmptyResponses++;
          debugPrint('[Home] empty response #$_consecutiveEmptyResponses');
          if (_consecutiveEmptyResponses < 3) {
            return;
          }
        } else {
          _consecutiveEmptyResponses = 0;
        }

        // ✅ لا rebuild إذا لم تتغير البيانات
        if (mounted && !_devicesEqual(_devices, list)) {
          setState(() => _devices = list);
        }
      } else if (response.statusCode == 403) {
        debugPrint('[Home] token rejected — logging out');
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('admin_token');
        _refreshTimer?.cancel();
        if (mounted) {
          setState(() {
            _adminToken = null;
            _devices = [];
            _consecutiveEmptyResponses = 0;
          });
        }
      } else if (response.statusCode == 503) {
        debugPrint('[Home] server temporarily unavailable (503)');
      } else {
        debugPrint('[Home] unexpected status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[Home] error loading devices: $e');
    } finally {
      _loadInFlight = false;
    }
  }

  Future<void> _sendWakeCommand(String sessionId) async {
    if (_adminToken == null) return;
    if (_wakingSessions.contains(sessionId)) return;

    setState(() => _wakingSessions.add(sessionId));

    WebSocket? ws;
    String result = 'failed';
    final completer = Completer<String>();

    try {
      final wsUrl = CameraService.server
              .replaceFirst("https://", "wss://")
              .replaceFirst("http://", "ws://") +
          "/signal";

      ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 10));

      ws.listen(
        (raw) {
          try {
            final msg = jsonDecode(raw as String);
            final type = msg['type'] as String?;
            if (type == 'wake-sent' && !completer.isCompleted) {
              completer.complete('sent');
            } else if (type == 'wake-failed' && !completer.isCompleted) {
              completer.complete('failed');
            }
          } catch (_) {}
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete('failed');
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete('failed');
        },
        cancelOnError: true,
      );

      ws.add(jsonEncode({
        'type': 'wake',
        'session': sessionId,
        'adminToken': _adminToken,
      }));

      result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => 'failed',
      );
    } catch (e) {
      debugPrint('[Wake] error: $e');
      result = 'failed';
    } finally {
      try {
        await ws?.close();
      } catch (_) {}

      if (mounted) {
        setState(() => _wakingSessions.remove(sessionId));

        final String text;
        final Color bg;
        if (result == 'sent') {
          text = '✅ تم إرسال الأمر — سيستجيب خلال ثوانٍ';
          bg = Colors.green;
        } else {
          text =
              '❌ الجهاز غير متصل بالسيرفر — يلزم فتح التطبيق على جهاز الطفل';
          bg = Colors.red;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(text),
            backgroundColor: bg,
            duration: const Duration(seconds: 4),
          ),
        );

        if (result == 'sent') {
          // ✅ تحديث فوري بعد الإيقاظ
          await Future.delayed(const Duration(seconds: 3));
          await _loadDevices();
        }
      }
    }
  }

  void _openAddDevice() {
    if (_adminToken == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddDeviceScreen(adminToken: _adminToken!),
      ),
    ).then((_) => _loadDevices());
  }

  void _openDevice(Map<String, dynamic> device) {
    if (_adminToken == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeviceConnectionScreen(
          sessionId: device['session_id'],
          name: device['name'],
          adminToken: _adminToken!,
        ),
      ),
    );
  }

  Future<void> _confirmForget(Map<String, dynamic> device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('نسيان هذا الجهاز'),
        content: Text(
          'هيتقطع الاتصال (لو شغال دلوقتي)، ولازم اقتران جديد بكود عشان '
          '"${device['name']}" يشتغل تاني. متأكد؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('نسيان الجهاز',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && _adminToken != null) {
      await CameraService.forgetDevice(device['session_id'], _adminToken!);
      await _loadDevices();
    }
  }

  Widget _buildLoginScreen() {
    return Scaffold(
      backgroundColor: const Color(0xfff1f5ff),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.videocam, size: 72, color: Colors.indigo),
                const SizedBox(height: 12),
                const Text(
                  'Camera Parent',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text(
                  'لوحة الوالد',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.black54),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _usernameController,
                  textInputAction: TextInputAction.next,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'اسم المستخدم',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  textDirection: TextDirection.ltr,
                  onSubmitted: (_) => _doLogin(register: false),
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                ),
                if (_authError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _authError!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 22),
                ElevatedButton(
                  onPressed:
                      _authLoading ? null : () => _doLogin(register: false),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                  ),
                  child: _authLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('تسجيل الدخول',
                          style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed:
                      _authLoading ? null : () => _doLogin(register: true),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  child: const Text('إنشاء حساب جديد',
                      style: TextStyle(fontSize: 15)),
                ),
                const SizedBox(height: 20),
                const Text(
                  'الحساب يُستخدم للدخول إلى كاميرات أطفالك.\n'
                  'احتفظ باسم المستخدم وكلمة المرور في مكان آمن.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDevicesScreen() {
    return Scaffold(
      backgroundColor: const Color(0xfff1f5ff),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('أجهزة الأطفال المقترنة',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'تحديث',
                        onPressed: () async {
                          await _loadDevices();
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${_devices.length} جهاز'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.logout),
                        tooltip: 'تسجيل الخروج',
                        onPressed: _logout,
                      ),
                      ElevatedButton.icon(
                        onPressed: _openAddDevice,
                        icon: const Icon(Icons.add),
                        label: const Text('إضافة جهاز'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _devices.isEmpty
                  ? const Center(child: Text('لا توجد أجهزة مقترنة بعد'))
                  : Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'اضغط ضغطة طويلة على أي جهاز لنسيانه',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.black45),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _devices.length,
                            itemBuilder: (context, i) {
                              final d = _devices[i];
                              final online = d['online'] == true;
                              final sessionId =
                                  d['session_id']?.toString() ?? '';
                              final isWaking =
                                  _wakingSessions.contains(sessionId);

                              return Card(
                                child: ListTile(
                                  leading: Icon(
                                    Icons.circle,
                                    size: 12,
                                    color: online
                                        ? Colors.green
                                        : Colors.grey,
                                  ),
                                  title: Text(d['name'] ?? ''),
                                  subtitle: Text(
                                      online ? 'متصل الآن' : 'غير متصل'),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!online)
                                        IconButton(
                                          icon: isWaking
                                              ? const SizedBox(
                                                  height: 18,
                                                  width: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2),
                                                )
                                              : const Icon(
                                                  Icons.refresh,
                                                  color: Colors.orange,
                                                ),
                                          tooltip: 'إرسال أمر إيقاظ للجهاز',
                                          onPressed: isWaking
                                              ? null
                                              : () =>
                                                  _sendWakeCommand(sessionId),
                                        ),
                                      const Icon(Icons.chevron_left),
                                    ],
                                  ),
                                  onTap: online ? () => _openDevice(d) : null,
                                  onLongPress: () => _confirmForget(d),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_adminToken == null) return _buildLoginScreen();
    return _buildDevicesScreen();
  }
}
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
    if (token == null || token.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _adminToken = token;
      _loading = false;
    });
    await _loadDevices();
    _startRefreshTimer();
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
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
      _usernameController.clear();
      _passwordController.clear();
      _authError = null;
    });
  }

  Future<void> _loadDevices() async {
    if (_adminToken == null) return;
    try {
      final response = await http.get(
        Uri.parse('${CameraService.server}/camera/sessions'),
        headers: {'X-Admin-Token': _adminToken!},
      );
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final list = (body['data'] as List).cast<Map<String, dynamic>>();
        if (mounted) setState(() => _devices = list);
      }
    } catch (_) {}
  }

  // ✅ زر الإيقاظ — يفتح WS مؤقت، يرسل wake، ثم يُغلق.
  Future<void> _sendWakeCommand(String sessionId) async {
    if (_adminToken == null) return;
    if (_wakingSessions.contains(sessionId)) return;

    setState(() => _wakingSessions.add(sessionId));

    WebSocket? ws;
    bool success = false;
    try {
      final wsUrl = CameraService.server
              .replaceFirst("https://", "wss://")
              .replaceFirst("http://", "ws://") +
          "/signal";

      ws = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 10));

      // register as viewer for this session
      ws.add(jsonEncode({
        'type': 'register',
        'role': 'viewer',
        'session': sessionId,
        'adminToken': _adminToken,
        'name': 'الوالد',
        'requestedSource': 'files',
      }));

      // انتظر قليلاً حتى يتسجل
      await Future.delayed(const Duration(milliseconds: 600));

      // أرسل wake
      ws.add(jsonEncode({'type': 'wake'}));

      // انتظر الرد
      await Future.delayed(const Duration(milliseconds: 1200));
      success = true;
    } catch (e) {
      debugPrint('[Wake] error: $e');
    } finally {
      try {
        await ws?.close();
      } catch (_) {}
      if (mounted) {
        setState(() => _wakingSessions.remove(sessionId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? '✅ تم إرسال أمر الإيقاظ للجهاز'
                  : '❌ فشل إرسال الأمر — تحقق من الشبكة',
            ),
            backgroundColor: success ? Colors.green : Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
        if (success) {
          // refresh بعد 3 ثواني
          Future.delayed(const Duration(seconds: 3), _loadDevices);
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
                                      // ✅ زر الإيقاظ — يظهر فقط عندما يكون الجهاز غير متصل
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
                                          tooltip: 'إعادة تشغيل الجهاز',
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

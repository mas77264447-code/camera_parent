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
  String? _error;
  List<Map<String, dynamic>> _devices = [];
  Timer? _refreshTimer;

  // شاشة الاسترجاع: username + password
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _recoveryLoading = false;
  String? _recoveryError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════
  // Recovery: Login with username + password
  // ═══════════════════════════════════════════════════════════
  Future<void> _tryManualRecovery() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() => _recoveryError = 'ادخل اسم المستخدم وكلمة المرور');
      return;
    }

    setState(() {
      _recoveryLoading = true;
      _recoveryError = null;
    });

    final result = await CameraService.parentLogin(username, password);

    if (result == null) {
      setState(() {
        _recoveryLoading = false;
        _recoveryError = 'اسم المستخدم أو كلمة المرور غير صحيحة';
      });
      return;
    }

    final token = result['token']!;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('admin_token', token);

    setState(() {
      _adminToken = token;
      _error = null;
      _loading = false;
      _recoveryLoading = false;
    });

    await _loadDevices();
    _refreshTimer?.cancel();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _loadDevices());
  }

  // ═══════════════════════════════════════════════════════════
  // Bootstrap
  // ═══════════════════════════════════════════════════════════
  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    var token = prefs.getString('admin_token');

    if (token == null) {
      try {
        final response = await http
            .post(Uri.parse('${CameraService.server}/admin/claim'))
            .timeout(const Duration(seconds: 10));
        final body = jsonDecode(response.body);

        if (response.statusCode == 200) {
          token = body['data']['admin_token'];
          await prefs.setString('admin_token', token!);
        } else {
          setState(() {
            _error = 'هذا السيرفر مرتبط بحساب والد آخر بالفعل.';
            _loading = false;
          });
          return;
        }
      } catch (e) {
        setState(() {
          _error = 'تعذر الاتصال بالسيرفر';
          _loading = false;
        });
        return;
      }
    }

    setState(() {
      _adminToken = token;
      _loading = false;
    });

    await _loadDevices();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _loadDevices());
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

  Future<void> _refreshDevices() async {
    await _loadDevices();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('تم التحديث — ${_devices.length} جهاز'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _restartAllDevices() async {
    if (_adminToken == null || _devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا توجد أجهزة لإعادة تشغيلها'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إعادة تشغيل الأجهزة'),
        content: Text(
          'سيتم إرسال أمر إيقاظ لـ ${_devices.length} جهاز.\n'
          'الجهاز سيعيد الاتصال بالسيرفر خلال ثوانٍ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('إرسال', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('جاري إرسال أوامر الإيقاظ لـ ${_devices.length} جهاز...'),
        duration: const Duration(seconds: 2),
      ),
    );

    int sent = 0;
    int failed = 0;
    for (final device in _devices) {
      final sessionId = device['session_id']?.toString();
      if (sessionId == null) continue;
      final ok = await _sendWakeCommand(sessionId);
      if (ok) {
        sent++;
      } else {
        failed++;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('تم الإرسال: $sent ✓ / فشل: $failed ✗'),
        duration: const Duration(seconds: 3),
      ),
    );

    await Future.delayed(const Duration(seconds: 3));
    await _loadDevices();
  }

  Future<bool> _sendWakeCommand(String sessionId) async {
    if (_adminToken == null) return false;
    try {
      // افتح اتصال WebSocket مؤقت لإرسال أمر الإيقاظ
      final wsUrl = CameraService.server
          .replaceFirst('https://', 'wss://')
          .replaceFirst('http://', 'ws://');
      final socket = await WebSocket.connect('$wsUrl/signal')
          .timeout(const Duration(seconds: 8));

      final completer = Completer<bool>();

      socket.listen(
        (raw) {
          try {
            final msg = jsonDecode(raw);
            if (msg['type'] == 'wake-sent' && !completer.isCompleted) {
              completer.complete(true);
            } else if (msg['type'] == 'wake-failed' && !completer.isCompleted) {
              completer.complete(false);
            }
          } catch (_) {}
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        cancelOnError: true,
      );

      socket.add(jsonEncode({
        'type': 'wake',
        'session': sessionId,
        'adminToken': _adminToken,
      }));

      final result = await completer.future
          .timeout(const Duration(seconds: 5), onTimeout: () => false);

      try {
        await socket.close();
      } catch (_) {}

      return result;
    } catch (e) {
      debugPrint('[Restart] error: $e');
      return false;
    }
  }

  void _openAddDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AddDeviceScreen(adminToken: _adminToken!)),
    ).then((_) => _loadDevices());
  }

  void _openDevice(Map<String, dynamic> device) {
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

  @override
  Widget build(BuildContext c) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
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
                  Icon(
                    Icons.lock_outline,
                    size: 56,
                    color: Colors.indigo.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text(
                    'استرجاع الاقتران',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'لو ده جهازك الأصلي وفقدت بيانات التطبيق بس، '
                    'ادخل اسم المستخدم وكلمة المرور بتوع حساب الوالد '
                    'للرجوع لنفس الحساب من غير اقتران جديد.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _usernameCtrl,
                    textInputAction: TextInputAction.next,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(
                      labelText: 'اسم المستخدم',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    textDirection: TextDirection.ltr,
                    onSubmitted: (_) => _tryManualRecovery(),
                    decoration: const InputDecoration(
                      labelText: 'كلمة المرور',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  if (_recoveryError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _recoveryError!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 14),
                  ElevatedButton(
                    onPressed: _recoveryLoading ? null : _tryManualRecovery,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                    ),
                    child: _recoveryLoading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('استرجاع', style: TextStyle(fontSize: 15)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xfff1f5ff),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('أجهزة الأطفال المقترنة',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'تحديث القائمة',
                    onPressed: _refreshDevices,
                  ),
                  IconButton(
                    icon: const Icon(Icons.power_settings_new,
                        color: Colors.orange),
                    tooltip: 'إعادة تشغيل الأجهزة',
                    onPressed: _restartAllDevices,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle,
                        color: Colors.indigo),
                    tooltip: 'إضافة جهاز',
                    onPressed: _openAddDevice,
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
                          padding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                              return Card(
                                child: ListTile(
                                  leading: Icon(Icons.circle,
                                      size: 12,
                                      color: online
                                          ? Colors.green
                                          : Colors.grey),
                                  title: Text(d['name'] ?? ''),
                                  subtitle:
                                      Text(online ? 'متصل الآن' : 'غير متصل'),
                                  trailing:
                                      const Icon(Icons.chevron_left),
                                  onTap:
                                      online ? () => _openDevice(d) : null,
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
}

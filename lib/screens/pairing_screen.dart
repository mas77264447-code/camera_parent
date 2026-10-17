import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/camera_service.dart';
import 'camera_stream_screen.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _parentUsernameController = TextEditingController();
  final _parentPasswordController = TextEditingController();
  final _nameController = TextEditingController(text: 'جهاز الطفل');

  bool _obscurePassword = true;
  bool _loading = false;
  bool _checkingSavedLogin = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _checkSavedLogin();
  }

  Future<void> _checkSavedLogin() async {
    final prefs = await SharedPreferences.getInstance();

    final isPaired = prefs.getBool('is_paired') ?? false;
    final deviceToken = prefs.getString('device_token');
    final sessionId = prefs.getString('session_id');
    final deviceName = prefs.getString('device_name');

    // ✅ تعبئة تلقائية لبيانات الدخول المحفوظة
    final savedUsername = prefs.getString('saved_username') ?? '';
    final savedPassword = prefs.getString('saved_password') ?? '';
    if (savedUsername.isNotEmpty) {
      _usernameController.text = savedUsername;
      _nameController.text = deviceName ?? 'جهاز الطفل';
    }
    if (savedPassword.isNotEmpty) {
      _passwordController.text = savedPassword;
    }

    if (isPaired &&
        deviceToken != null &&
        deviceToken.isNotEmpty &&
        sessionId != null &&
        sessionId.isNotEmpty) {
      WakelockPlus.disable();

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CameraStreamScreen(
            sessionId: sessionId,
            cameraName: deviceName ?? 'جهاز الطفل',
            deviceToken: deviceToken,
          ),
        ),
      );

      return;
    }

    if (!mounted) return;

    setState(() {
      _checkingSavedLogin = false;
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _parentUsernameController.dispose();
    _parentPasswordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loginWithParent() async {
    final parentUsername = _parentUsernameController.text.trim();
    final parentPassword = _parentPasswordController.text;
    final deviceName = _nameController.text.trim();

    if (deviceName.isEmpty) {
      setState(() => _error = 'أدخل اسم الجهاز');
      return;
    }

    if (parentUsername.isEmpty) {
      setState(() => _error = 'أدخل اسم مستخدم الوالد');
      return;
    }

    if (parentPassword.isEmpty) {
      setState(() => _error = 'أدخل كلمة مرور الوالد');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http.post(
        Uri.parse('${CameraService.server}/pairing/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'device_name': _nameController.text.trim(),
          'code': _codeController.text.trim(),
        }),
      // 45 ثانية: السيرفر على استضافة مجانية قد يحتاج وقتاً للاستيقاظ بعد الخمول
      ).timeout(const Duration(seconds: 45), onTimeout: () {
        throw TimeoutException('انتهت مهلة الاتصال');
      });

      if (response.statusCode != 200) {
        String msg = 'حدث خطأ، حاول مرة أخرى';
        try {
          final b = jsonDecode(response.body);
          if (b is Map && b['error'] != null) msg = b['error'].toString();
        } catch (_) {
          // الرد ليس JSON (مثلاً صفحة خطأ من الاستضافة)
          msg = 'السيرفر غير متاح حالياً (${response.statusCode}). حاول بعد قليل.';
        }
        if (!mounted) return;
        setState(() {
          _error = msg;
          _loading = false;
        });

        return;
      }

      final data = body['data'];

      if (data is! Map ||
          data['device_token'] == null ||
          data['session_id'] == null) {
        if (!mounted) return;

        setState(() {
          _error = 'السيرفر أعاد بيانات تسجيل غير صحيحة.';
          _loading = false;
        });

        return;
      }

      final deviceToken = data['device_token'].toString();
      final sessionId = data['session_id'].toString();
      final returnedDeviceName =
          data['device_name']?.toString().isNotEmpty == true
              ? data['device_name'].toString()
              : deviceName;

      final prefs = await SharedPreferences.getInstance();

      await prefs.setString('device_token', deviceToken);
      await prefs.setString('session_id', sessionId);
      await prefs.setString('device_name', returnedDeviceName);
      await prefs.setBool('is_paired', true);
      // ✅ حفظ بيانات الدخول لتعبئتها تلقائياً في المرة القادمة
      await prefs.setString('saved_username', username);
      await prefs.setString('saved_password', password);

      // لا نحفظ parent_username أو parent_password.
      await prefs.remove('parent_username');
      await prefs.remove('parent_password');
      await prefs.remove('username');
      await prefs.remove('password');

      WakelockPlus.disable();

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CameraStreamScreen(
            sessionId: sessionId,
            cameraName: returnedDeviceName,
            deviceToken: deviceToken,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر الاتصال بالسيرفر: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSavedLogin) {
      return const Scaffold(
        backgroundColor: Color(0xfff1f5ff),
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          WakelockPlus.disable();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xfff1f5ff),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.family_restroom,
                    size: 60,
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 16),

                  const Text(
                    'ربط جهاز الطفل',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 10),

                  const Text(
                    'أدخل اسم الجهاز وبيانات حساب الوالد لربط هذا الجهاز بحساب الوالد.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.black54,
                    ),
                  ),

                  const SizedBox(height: 24),

                  TextField(
                    controller: _nameController,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      labelText: 'اسم هذا الجهاز',
                      hintText: 'مثال: جهاز أحمد',
                      border: OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(height: 12),

                  TextField(
                    controller: _parentUsernameController,
                    textAlign: TextAlign.center,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'اسم مستخدم الوالد',
                      border: OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(height: 12),

                  TextField(
                    controller: _parentPasswordController,
                    obscureText: _obscurePassword,
                    textAlign: TextAlign.center,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'كلمة مرور الوالد',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],

                  const SizedBox(height: 18),

                  ElevatedButton(
                    onPressed: _loading ? null : _loginWithParent,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                    ),
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('دخول وربط الجهاز'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

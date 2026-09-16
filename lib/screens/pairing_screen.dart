import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/secure_store.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/camera_service.dart';
import 'camera_stream_screen.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController(text: 'جهاز الطفل');
  // كود الوالد مطلوب أول مرة بس (لما اليوزر بيتسجل لأول مرة). لو
  // الحساب موجود بالفعل، السيرفر بيتجاهل الكود ويتحقق من الباسورد بس.
  final _codeController = TextEditingController();
  bool _obscurePassword = true;
  bool _loading = false;
  // true لحد ما نتأكد إن مفيش تسجيل دخول محفوظ قبل كده - بنسيب الشاشة
  // فاضية (Splash بسيط) في الوقت ده عشان مايبانش فورم الدخول للحظة
  // واحدة ثم يختفي فجأة لو كان فيه بيانات محفوظة.
  bool _checkingSavedLogin = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _checkSavedLogin();
  }

  // لو الجهاز مسجل دخول قبل كده (فيه device_token/session_id محفوظين)،
  // نروح على طول لشاشة البث من غير ما نعرض فورم اليوزر والباسورد تاني.
  Future<void> _checkSavedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final isPaired = prefs.getBool('is_paired') ?? false;
    final deviceToken = await SecureStore.read('device_token');
    final sessionId = prefs.getString('session_id');
    final deviceName = prefs.getString('device_name');

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
    setState(() => _checkingSavedLogin = false);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _usernameController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty) {
      setState(() => _error = 'أدخل اسم المستخدم');
      return;
    }
    if (password.length < 12) {
      setState(() => _error = 'كلمة المرور لازم تكون 12 حرفًا على الأقل');
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
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        throw TimeoutException('انتهت مهلة الاتصال');
      });

      if (response.statusCode != 200) {
        final body = jsonDecode(response.body);
        setState(() {
          _error = body['error'] ?? 'حدث خطأ، حاول مرة أخرى';
          _loading = false;
        });
        return;
      }

      final body = jsonDecode(response.body);
      final data = body['data'];
      final prefs = await SharedPreferences.getInstance();
      await SecureStore.write('device_token', data['device_token']);
      await prefs.setString('session_id', data['session_id']);
      await prefs.setString('device_name', data['device_name']);
      await prefs.setBool('is_paired', true);

      WakelockPlus.disable();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CameraStreamScreen(
            sessionId: data['session_id'],
            cameraName: data['device_name'],
            deviceToken: data['device_token'],
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _error = 'خطأ: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSavedLogin) {
      return const Scaffold(
        backgroundColor: Color(0xfff1f5ff),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return WillPopScope(
      onWillPop: () async {
        WakelockPlus.disable();
        return true;
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
                  const Icon(Icons.link, size: 56, color: Colors.blue),
                  const SizedBox(height: 16),
                  const Text(
                    'تسجيل الدخول',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'أول مرة؟ هتحتاج كود من تطبيق الوالد (شاشة "إضافة '
                    'جهاز") مرة واحدة بس. بعد كده اسم المستخدم وكلمة '
                    'المرور هيتحفظوا تلقائيًا على الجهاز ده والمرات '
                    'الجاية هتدخل مباشرة من غير ما يطلبهم منك تاني.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'اسم هذا الجهاز',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _usernameController,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      labelText: 'اسم المستخدم',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      labelText: 'كلمة المرور',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeController,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'كود من تطبيق الوالد (أول مرة بس)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: const TextStyle(color: Colors.red, fontSize: 13),
                        textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loading ? null : _register,
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
                    child: _loading
                        ? const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('دخول'),
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

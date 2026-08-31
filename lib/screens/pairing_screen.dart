import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/camera_service.dart';
import 'camera_stream_screen.dart';

/// شاشة الإعداد الأولى على جهاز الطفل: بتتعرض مرة واحدة بس لحد ما
/// الجهاز يتقرن بحساب الوالد عن طريق كود من 6 أرقام. مفيش أي رابط
/// يتفتح هنا - الكود بيتكتب يدويًا على نفس الجهاز اللي هيتبث بعدها.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController(text: 'جهاز الطفل');
  bool _loading = false;
  String? _error;

  Future<void> _claim() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'أدخل كود الاقتران المكوّن من 6 أرقام');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http.post(
        Uri.parse('${CameraService.server}/pairing/claim'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'device_name': _nameController.text.trim(),
        }),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode != 200) {
        setState(() {
          _error = body['error'] ?? 'الكود غير صحيح أو منتهي الصلاحية';
          _loading = false;
        });
        return;
      }

      final data = body['data'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('device_token', data['device_token']);
      await prefs.setString('session_id', data['session_id']);
      await prefs.setString('device_name', data['device_name']);
      await prefs.setBool('is_paired', true);

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
        _error = 'تعذر الاتصال بالسيرفر. تأكد من الإنترنت وحاول مرة ثانية.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff1f5ff),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.link, size: 56, color: Colors.blue),
              const SizedBox(height: 16),
              const Text(
                'اقتران الجهاز',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'اطلب من الوالد كود الاقتران المكوّن من 6 أرقام من تطبيقه، '
                'وأدخله هنا لربط هذا الجهاز بحسابه. هذا الإجراء يتم مرة '
                'واحدة فقط، وسيظهر إشعار دائم على هذا الجهاز طوال أي '
                'جلسة بث لاحقة.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم هذا الجهاز (يظهر عند الوالد)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 6,
                style: const TextStyle(fontSize: 28, letterSpacing: 8),
                decoration: const InputDecoration(
                  labelText: 'كود الاقتران',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loading ? null : _claim,
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
                child: _loading
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('اقتران'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

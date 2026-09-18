import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/camera_service.dart';

class AddDeviceScreen extends StatefulWidget {
  final String adminToken;
  const AddDeviceScreen({super.key, required this.adminToken});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  String? _code;
  int _secondsLeft = 0;
  Timer? _timer;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generateCode();
  }

  Future<void> _generateCode() async {
    setState(() {
      _loading = true;
      _error = null;
      _code = null;
    });
    _timer?.cancel();

    try {
      final response = await http.post(
        Uri.parse('${CameraService.server}/pairing/create'),
        headers: {
          'Content-Type': 'application/json',
          'X-Admin-Token': widget.adminToken,
        },
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        throw TimeoutException('اتصال الخادم استغرق وقتاً طويلاً');
      });

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint('Server error: ${response.statusCode} - ${response.body}');
        }
        setState(() {
          _error = 'خطأ من السيرفر: ${response.statusCode}';
          _loading = false;
        });
        return;
      }

      final body = jsonDecode(response.body);
      final data = body['data'];
      
      setState(() {
        _code = data['code'];
        _secondsLeft = (data['expires_in_seconds'] as num).toInt();
        _loading = false;
      });

      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() {
          _secondsLeft--;
        });
        if (_secondsLeft <= 0) {
          t.cancel();
          setState(() => _code = null);
        }
      });
    } on TimeoutException catch (e) {
      setState(() {
        _error = 'انتهت مهلة الاتصال - تحقق من الإنترنت';
        _loading = false;
      });
      if (kDebugMode) {
        debugPrint('Timeout: $e');
      }
    } catch (e) {
      setState(() {
        _error = 'تعذر الاتصال بالسيرفر: $e';
        _loading = false;
      });
      if (kDebugMode) {
        debugPrint('Error: $e');
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إضافة جهاز جديد')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.smartphone, size: 48, color: Colors.blue),
            const SizedBox(height: 16),
            const Text(
              'افتح تطبيق الطفل على الجهاز المراد ربطه، واختر "اقتران '
              'جهاز جديد"، ثم أدخل الكود التالي هناك:',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 28),
            if (_loading)
              const CircularProgressIndicator()
            else if (_error != null)
              Column(
                children: [
                  Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _generateCode, child: const Text('إعادة المحاولة')),
                ],
              )
            else if (_code != null)
              Column(
                children: [
                  Text(
                    _code!,
                    style: const TextStyle(fontSize: 42, fontWeight: FontWeight.bold, letterSpacing: 8),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ينتهي خلال ${_secondsLeft}s',
                    style: const TextStyle(color: Colors.black45, fontSize: 13),
                  ),
                ],
              )
            else
              Column(
                children: [
                  const Text('انتهت صلاحية الكود', style: TextStyle(color: Colors.orange)),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _generateCode, child: const Text('كود جديد')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

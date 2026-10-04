import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../services/camera_service.dart';

class WebLinkScreen extends StatefulWidget {
  final String adminToken;

  const WebLinkScreen({
    super.key,
    required this.adminToken,
  });

  @override
  State<WebLinkScreen> createState() => _WebLinkScreenState();
}

class _WebLinkScreenState extends State<WebLinkScreen> {
  String? _code;
  int _secondsLeft = 0;
  Timer? _timer;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
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
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
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
        setState(() => _secondsLeft--);
        if (_secondsLeft <= 0) {
          t.cancel();
          setState(() => _code = null);
        }
      });
    } catch (e) {
      setState(() {
        _error = 'تعذر الاتصال: $e';
        _loading = false;
      });
    }
  }

  String get _link {
    if (_code == null) return '';
    return '${CameraService.server}/child.html?code=$_code';
  }

  Future<void> _copy() async {
    if (_code == null) return;
    await Clipboard.setData(ClipboardData(text: _link));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ تم نسخ الرابط'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إضافة عبر رابط'),
        actions: [
          if (_code != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _generate,
              tooltip: 'كود جديد',
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error, color: Colors.red, size: 48),
                        const SizedBox(height: 16),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _generate,
                          child: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ),
                  ),
                )
              : _code == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.timer_off,
                              size: 48, color: Colors.orange),
                          const SizedBox(height: 16),
                          const Text('انتهت صلاحية الكود'),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _generate,
                            child: const Text('كود جديد'),
                          ),
                        ],
                      ),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _code!,
                              style: TextStyle(
                                fontSize: 42,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 10,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.timer,
                                    size: 14, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(
                                  'ينتهي خلال $_secondsLeft ث',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 40),
                            ElevatedButton.icon(
                              onPressed: _copy,
                              icon: const Icon(Icons.copy, size: 22),
                              label: const Text(
                                'نسخ الرابط',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 58),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
    );
  }
}

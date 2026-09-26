import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import '../services/camera_service.dart';

class WebLinkScreen extends StatefulWidget {
  final String adminToken;
  final String deviceName;

  const WebLinkScreen({
    super.key,
    required this.adminToken,
    required this.deviceName,
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
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // الكود
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xff4a7aff), Color(0xff6b5cff)],
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                const Text('كود الاقتران',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 13)),
                                const SizedBox(height: 8),
                                Text(
                                  _code!,
                                  style: const TextStyle(
                                    fontSize: 40,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: 8,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.timer,
                                        size: 14, color: Colors.white70),
                                    const SizedBox(width: 4),
                                    Text('ينتهي خلال $_secondsLeft ث',
                                        style: const TextStyle(
                                            color: Colors.white70, fontSize: 12)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),

                          // QR Code
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: QrImageView(
                                data: _link,
                                version: QrVersions.auto,
                                size: 200,
                                backgroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // الرابط
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SelectableText(
                              _link,
                              style: const TextStyle(fontSize: 11),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // نسخ
                          ElevatedButton.icon(
                            onPressed: _copy,
                            icon: const Icon(Icons.copy),
                            label: const Text('نسخ الرابط'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(double.infinity, 48),
                            ),
                          ),
                          const SizedBox(height: 20),

                          // التعليمات
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.amber.shade200),
                            ),
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.info_outline,
                                        color: Colors.orange, size: 20),
                                    SizedBox(width: 8),
                                    Text('كيف يعمل الرابط؟',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13)),
                                  ],
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '1. افتح الرابط على جهاز الطفل (أي متصفح)\n'
                                  '2. أدخل اسم الجهاز واضغط "بدء البث"\n'
                                  '3. امنح صلاحيات الكاميرا\n'
                                  '4. اترك الصفحة مفتوحة\n\n'
                                  '⚠️ الرابط يعمل للكاميرا فقط — لا يدعم الملفات أو بث الشاشة\n'
                                  '⚠️ يعمل فقط أثناء فتح الصفحة',
                                  style: TextStyle(fontSize: 12, height: 1.6),
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
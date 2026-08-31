import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/camera_service.dart';
import 'add_device_screen.dart';
import 'camera_viewer_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    var token = prefs.getString('admin_token');

    if (token == null) {
      try {
        final response = await http.post(Uri.parse('${CameraService.server}/admin/claim'));
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
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadDevices());
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

  void _openAddDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddDeviceScreen(adminToken: _adminToken!)),
    ).then((_) => _loadDevices());
  }

  void _openDevice(Map<String, dynamic> device) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CameraViewerScreen(
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
            child: const Text('نسيان الجهاز', style: TextStyle(color: Colors.red)),
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
      return Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!, textAlign: TextAlign.center),
      )));
    }

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
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    onPressed: _openAddDevice,
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة جهاز'),
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
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'اضغط ضغطة طويلة على أي جهاز لنسيانه',
                              style: TextStyle(fontSize: 11, color: Colors.black45),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _devices.length,
                            itemBuilder: (context, i) {
                              final d = _devices[i];
                              final online = d['online'] == true;
                              return Card(
                                child: ListTile(
                                  leading: Icon(Icons.circle,
                                      size: 12, color: online ? Colors.green : Colors.grey),
                                  title: Text(d['name'] ?? ''),
                                  subtitle: Text(online ? 'متصل الآن' : 'غير متصل'),
                                  trailing: const Icon(Icons.chevron_left),
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
}

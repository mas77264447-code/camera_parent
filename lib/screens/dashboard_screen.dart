import 'dart:async';
import 'package:flutter/material.dart';
import '../services/camera_service.dart';
import 'camera_viewer_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _timer;
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  Future<void> _load() async {
    try {
      final sessions = await CameraService.fetchSessions();

      if (!mounted) return;

      setState(() {
        _sessions = sessions;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = "تعذر تحميل قائمة الكاميرات: $e";
      });
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
      appBar: AppBar(
        title: const Text("الكاميرات المتصلة"),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                )
              : _sessions.isEmpty
                  ? const Center(child: Text("مفيش كاميرات لسه"))
                  : ListView.separated(
                      itemCount: _sessions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final session = _sessions[index];
                        final bool online = session["online"] == true;

                        return ListTile(
                          leading: Icon(
                            Icons.circle,
                            size: 14,
                            color: online ? Colors.green : Colors.grey,
                          ),
                          title: Text(session["name"] ?? "بدون اسم"),
                          subtitle: Text(online ? "متصلة الآن" : "غير متصلة"),
                          trailing: const Icon(Icons.chevron_left),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CameraViewerScreen(
                                  sessionId: session["session_id"],
                                  name: session["name"] ?? "بدون اسم",
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}

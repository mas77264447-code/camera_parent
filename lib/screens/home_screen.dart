import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/camera_service.dart';
import 'camera_stream_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepareAndGo();
  }

  Future<void> _prepareAndGo() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      String? sessionId = prefs.getString("session_id");
      String? cameraName = prefs.getString("camera_name");
      String? childUrl = prefs.getString("child_url");
      String? dashboardUrl = prefs.getString("dashboard_url");

      if (sessionId == null) {
        // أول مرة يفتح فيها التطبيق - ننشئ الكاميرا مرة واحدة وتفضل ثابتة بعد كده
        cameraName = "الكاميرا الرئيسية";

        final result = await CameraService.createCameraSession(cameraName);

        if (result == null) {
          throw Exception("تعذر الاتصال بالسيرفر");
        }

        sessionId = result["session_id"];
        childUrl = result["child_url"];
        dashboardUrl = result["dashboard_url"];

        await prefs.setString("session_id", sessionId!);
        await prefs.setString("camera_name", cameraName);
        await prefs.setString("child_url", childUrl!);
        await prefs.setString("dashboard_url", dashboardUrl!);
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => CameraStreamScreen(
            sessionId: sessionId!,
            cameraName: cameraName!,
            childUrl: childUrl,
            dashboardUrl: dashboardUrl,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "حصل خطأ: $e\n\nتأكد إن الموبايل متصل بالإنترنت.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _prepareAndGo();
                      },
                      child: const Text("إعادة المحاولة"),
                    ),
                  ],
                ),
              )
            : const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text("جاري تجهيز الكاميرا..."),
                ],
              ),
      ),
    );
  }
}

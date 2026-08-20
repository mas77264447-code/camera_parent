import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/camera_service.dart';

class CameraStreamScreen extends StatefulWidget {
  final String sessionId;

  const CameraStreamScreen({super.key, required this.sessionId});

  @override
  State<CameraStreamScreen> createState() => _CameraStreamScreenState();
}

class _CameraStreamScreenState extends State<CameraStreamScreen> {
  CameraController? _controller;
  Timer? _timer;
  bool _ready = false;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final status = await Permission.camera.request();

    if (!status.isGranted) {
      setState(() {
        _error = "لازم تسمح للتطبيق بالوصول للكاميرا من إعدادات الموبايل";
      });
      return;
    }

    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        setState(() {
          _error = "مفيش كاميرا متاحة على الجهاز";
        });
        return;
      }

      _controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();

      if (!mounted) return;

      setState(() {
        _ready = true;
      });

      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _captureAndUpload(),
      );
    } catch (e) {
      setState(() {
        _error = "خطأ في تشغيل الكاميرا: $e";
      });
    }
  }

  Future<void> _captureAndUpload() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_uploading) return;

    _uploading = true;

    try {
      final file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      await CameraService.uploadFrame(widget.sessionId, bytes);
    } catch (_) {
      // نتجاهل الأخطاء المؤقتة، هنحاول تاني في الدورة الجاية
    } finally {
      _uploading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("البث شغال"),
        centerTitle: true,
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : !_ready
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(child: CameraPreview(_controller!)),
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: Colors.black87,
                      child: const Text(
                        "البث شغال - سيبيه فاتح عشان يكمل يبعت الصور",
                        style: TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
    );
  }
}

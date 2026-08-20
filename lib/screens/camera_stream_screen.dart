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
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;

  bool _ready = false;
  bool _uploading = false;
  String? _error;

  // Debug/diagnostics
  String _permissionStatus = "لسه ما اتفحصتش";
  String _cameraStatus = "لسه ما بدأتش";
  int _sentCount = 0;
  int _failCount = 0;
  String _lastResult = "-";
  String _lastTime = "-";

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final status = await Permission.camera.request();

    setState(() {
      _permissionStatus = status.toString();
    });

    if (!status.isGranted) {
      setState(() {
        _error = "لازم تسمح للتطبيق بالوصول للكاميرا من إعدادات الموبايل";
      });
      return;
    }

    try {
      _cameras = await availableCameras();

      setState(() {
        _cameraStatus = "عدد الكاميرات المتاحة: ${_cameras.length}";
      });

      if (_cameras.isEmpty) {
        setState(() {
          _error = "مفيش كاميرا متاحة على الجهاز";
        });
        return;
      }

      await _startCamera(_cameras[_cameraIndex]);

      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _captureAndUpload(),
      );
    } catch (e) {
      setState(() {
        _error = "خطأ في تشغيل الكاميرا: $e";
        _cameraStatus = "فشل: $e";
      });
    }
  }

  Future<void> _startCamera(CameraDescription description) async {
    final oldController = _controller;

    final newController = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    try {
      await newController.initialize();

      await oldController?.dispose();

      if (!mounted) return;

      setState(() {
        _controller = newController;
        _ready = true;
        _error = null;
        _cameraStatus = "الكاميرا شغالة (${description.lensDirection})";
      });
    } catch (e) {
      setState(() {
        _error = "فشل تشغيل الكاميرا: $e";
        _cameraStatus = "فشل: $e";
      });
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;

    setState(() {
      _ready = false;
    });

    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _startCamera(_cameras[_cameraIndex]);
  }

  Future<void> _captureAndUpload() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_uploading) return;

    _uploading = true;

    try {
      final file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();

      await CameraService.uploadFrame(widget.sessionId, bytes);

      _sentCount++;

      if (mounted) {
        setState(() {
          _lastResult = "نجح ✓ (${bytes.length} بايت)";
          _lastTime = DateTime.now().toString().substring(11, 19);
        });
      }
    } catch (e) {
      _failCount++;

      if (mounted) {
        setState(() {
          _lastResult = "فشل ✗ : $e";
          _lastTime = DateTime.now().toString().substring(11, 19);
        });
      }
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
        actions: [
          if (_cameras.length > 1)
            IconButton(
              icon: const Icon(Icons.cameraswitch),
              onPressed: _switchCamera,
              tooltip: "تبديل الكاميرا",
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _error != null
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
                : !_ready || _controller == null
                    ? const Center(child: CircularProgressIndicator())
                    : CameraPreview(_controller!),
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.black,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("الصلاحية: $_permissionStatus", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Text("الكاميرا: $_cameraStatus", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Text("عدد الصور المرسلة بنجاح: $_sentCount | فشل: $_failCount", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Text("آخر محاولة ($_lastTime): $_lastResult", style: const TextStyle(color: Colors.amber, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

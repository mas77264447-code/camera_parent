import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// ✅ imports صحيحة من مجلد services
import '../services/stream_service.dart';
import '../services/camera_service.dart';
import '../services/connection_state_manager.dart';
import '../services/file_access_service.dart';
import '../services/screen_capture_service.dart';
import '../services/crypto_service.dart';
import '../services/fcm_service.dart';

class CameraStreamScreen extends StatefulWidget {
  final String sessionId;
  final String deviceToken;
  final String cameraName;

  const CameraStreamScreen({
    super.key,
    required this.sessionId,
    required this.deviceToken,
    required this.cameraName,
  });

  @override
  State<CameraStreamScreen> createState() => _CameraStreamScreenState();
}

class _CameraStreamScreenState extends State<CameraStreamScreen> {
  final _service = StreamService.instance;

  @override
  void initState() {
    super.initState();
    _service.start(
      sessionId: widget.sessionId,
      deviceToken: widget.deviceToken,
      cameraName: widget.cameraName,
    );
  }

  // ⚠️ لا تستدعِ _service.stop() في dispose() — الخدمة يجب أن تستمر
  // في الخلفية بعد إغلاق الشاشة.

  @override
  Widget build(BuildContext context) {
    // ... كود الواجهة فقط (StreamBuilder, FutureBuilder, إلخ)
    // أي استخدام لـ StreamService يجب أن يكون عبر _service.xxx
    return Scaffold(
      appBar: AppBar(title: Text(widget.cameraName)),
      body: StreamBuilder<String>(
        stream: _service.onStatus,
        builder: (context, snapshot) {
          return Center(child: Text(snapshot.data ?? 'جاري التجهيز...'));
        },
      ),
    );
  }
}
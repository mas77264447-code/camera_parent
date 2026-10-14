import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/stream_service.dart';


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

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  StreamSubscription<String>? _statusSub;
  StreamSubscription<MediaStream?>? _localSub;
  StreamSubscription<Map<String, MediaStream>>? _remoteSub;
  StreamSubscription<Map<String, String>>? _pendingSub;

  String _status = 'جاري التجهيز...';
  Map<String, String> _pending = {};
  MediaStream? _localStream;

  @override
  void initState() {
    super.initState();

    _localRenderer.initialize();

    _statusSub = _service.onStatus.listen((s) {
      if (mounted) setState(() => _status = s);
    });

    _localSub = _service.onLocalStream.listen((s) {
      if (!mounted) return;
      setState(() => _localStream = s);
      _localRenderer.srcObject = s;
    });

    _pendingSub = _service.onPendingRequests.listen((p) {
      if (mounted) setState(() => _pending = p);
    });

    _remoteSub = _service.onRemoteStreams.listen((_) {
      if (mounted) setState(() {});
    });

    // ابدأ الخدمة (idempotent — لا ضرر إن كانت تعمل)
    unawaited(_service.start(
      sessionId: widget.sessionId,
      deviceToken: widget.deviceToken,
      cameraName: widget.cameraName,
    ));
  }

  @override
  void dispose() {
    // ⚠️ لا تستدعِ _service.stop() هنا — الخدمة يجب أن تستمر في الخلفية.
    _statusSub?.cancel();
    _localSub?.cancel();
    _remoteSub?.cancel();
    _pendingSub?.cancel();
    _localRenderer.dispose();
    super.dispose();
  }

  Future<void> _approve(String viewerId) async {
    await _service.approvePendingViewer(viewerId, 'camera');
  }

  void _reject(String viewerId) {
    _service.rejectPendingViewer(viewerId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.cameraName),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            tooltip: 'تبديل الكاميرا',
            onPressed: _service.running ? _service.switchCamera : null,
          ),
        ],
      ),
      body: Column(
        children: [
          // معاينة محلية للكاميرا
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _localStream != null
                      ? RTCVideoView(
                          _localRenderer,
                          mirror: false,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                      : const Center(
                          child: Icon(
                            Icons.videocam_off,
                            size: 80,
                            color: Colors.white24,
                          ),
                        ),
                ),
                // شريط الحالة
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _status,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // طلبات المشاهدة المعلّقة
          if (_pending.isNotEmpty)
            Container(
              color: Colors.orange.shade900,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'طلبات مشاهدة جديدة',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._pending.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.value,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _approve(e.key),
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.green,
                            ),
                            child: const Text(
                              'موافقة',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () => _reject(e.key),
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                            child: const Text(
                              'رفض',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
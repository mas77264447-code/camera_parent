import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/viewer_connection_controller.dart';

/// شاشة مشاهدة الأب: واجهة فقط — كل منطق الإشارة/WebRTC/المراقبات موجود في
/// [ViewerConnectionController]. هذا الفصل يسهّل اختبار منطق الاتصال
/// بمعزل عن الواجهة، ويمنع تضخّم ملف الشاشة بتفاصيل شبكة لا علاقة لها
/// بالعرض.
class CameraViewerScreen extends StatefulWidget {
  final String sessionId;
  final String name;
  final String adminToken;
  final String? initialSource;

  const CameraViewerScreen({
    super.key,
    required this.sessionId,
    required this.name,
    required this.adminToken,
    this.initialSource,
  });

  @override
  State<CameraViewerScreen> createState() => _CameraViewerScreenState();
}

class _CameraViewerScreenState extends State<CameraViewerScreen>
    with WidgetsBindingObserver {
  late final ViewerConnectionController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ViewerConnectionController(
      sessionId: widget.sessionId,
      name: widget.name,
      adminToken: widget.adminToken,
      initialSource: widget.initialSource,
    )..addListener(_onControllerChanged);
    _controller.start(chooseSource: _chooseRequestedSource);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.onAppResumed();
    }
  }

  Future<String?> _chooseRequestedSource() {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('اختر مصدر البث'),
        content: const Text('هل تريد بث الكاميرا أم مشاركة شاشة الجهاز؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'camera'),
            child: const Text('📷 الكاميرا'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'screen'),
            child: const Text('🖥️ الشاشة'),
          ),
        ],
      ),
    );
  }

  Future<bool> _handleBack() async {
    await _controller.leaveSession();
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'رجوع',
            onPressed: () async {
              await c.leaveSession();
              if (mounted) Navigator.of(context).pop();
            },
          ),
          title: Text(c.isScreenShare ? '${widget.name} - الشاشة' : widget.name),
          centerTitle: true,
          actions: [
            if (c.remoteStream != null)
              IconButton(
                icon: Icon(c.remoteAudioMuted ? Icons.volume_off : Icons.volume_up),
                onPressed: c.toggleRemoteAudio,
                tooltip: c.remoteAudioMuted ? 'تشغيل صوت الطفل' : 'كتم صوت الطفل',
              ),
            if (!c.isScreenShare)
              IconButton(
                icon: const Icon(Icons.cameraswitch),
                onPressed: c.remoteStream != null ? c.switchRemoteCamera : null,
                tooltip: 'تبديل كاميرا الطفل (أمامية/خلفية)',
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: RTCVideoView(c.remoteRenderer)),
                  Positioned(
                    top: 4,
                    left: 4,
                    right: 4,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        color: Colors.black54,
                        child: Text(
                          c.diag,
                          style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                        ),
                      ),
                    ),
                  ),
                  if (c.isScreenShare && c.remoteStream != null)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.red.shade700,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.screen_share, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text(
                              'بث الشاشة',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (c.rejected)
                    const Positioned.fill(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.block, color: Colors.red, size: 48),
                              SizedBox(height: 12),
                              Text(
                                'صاحب الكاميرا رفض طلب الاتصال',
                                style: TextStyle(color: Colors.white70, fontSize: 15),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: Colors.black87,
              child: Text(
                c.status,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

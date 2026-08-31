import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/camera_service.dart';

/// شاشة الوالد: بتتصل بالسيرفر بدور "viewer" (زائر) عن طريق الـ
/// adminToken بتاعه، وبتستنى الجهاز المُبث (broadcaster) يبعت "offer"
/// عشان تعمل "answer" وتعرض بثه. مفيش أي تسجيل بدور broadcaster هنا -
/// الشاشة دي بس بتشوف/تتصل، ومش هي مصدر البث.
class CameraViewerScreen extends StatefulWidget {
  final String sessionId;
  final String name;
  final String adminToken;

  const CameraViewerScreen({
    super.key,
    required this.sessionId,
    required this.name,
    required this.adminToken,
  });

  @override
  State<CameraViewerScreen> createState() => _CameraViewerScreenState();
}

class _CameraViewerScreenState extends State<CameraViewerScreen> with WidgetsBindingObserver {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _remoteStream;
  MediaStream? _localStream;
  WebSocket? _ws;

  // معرّف جهاز الطفل (broadcaster) بتاع الجلسة دي - بيوصلنا مع أول
  // "offer"، ومحتاجينه عشان نبعت عليه ice candidates وأوامر التحكم
  // (تبديل كاميرا / كتم مايك).
  String? _broadcasterId;

  bool _renderersReady = false;
  bool _connecting = true;
  bool _hasRemoteVideo = false;
  String? _error;
  String _status = "جاري الاتصال...";

  bool _localAudioEnabled = true;
  bool _showLocalPreview = false;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  List<Map<String, dynamic>> _iceServers = const [
    {"urls": "stun:stun.l.google.com:19302"},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshRemoteVideoTexture();
    }
  }

  void _refreshRemoteVideoTexture() {
    // نفس إصلاح مشكلة الـ texture السودة بتاعة flutter_webrtc بعد رجوع
    // التطبيق من الخلفية - موجودة في شاشة الطفل، وبتحصل هنا بنفس الشكل.
    final stream = _remoteStream;
    if (stream != null) {
      _remoteRenderer.srcObject = null;
      Future.microtask(() {
        if (mounted) {
          setState(() {
            _remoteRenderer.srcObject = stream;
          });
        }
      });
    }
  }

  Future<void> _init() async {
    setState(() {
      _connecting = true;
      _error = null;
      _status = "جاري التجهيز...";
    });

    if (!_renderersReady) {
      await _remoteRenderer.initialize();
      await _localRenderer.initialize();
      _renderersReady = true;
    }

    unawaited(_loadIceServers());

    // كاميرا/مايك الوالد اختياريين - لو اتوافق عليهم هنبعت فيديو/صوت
    // رجوع للجهاز التاني (زي مكالمة فيديو ثنائية)، ولو مش متاحين هنكمل
    // في وضع مشاهدة بس (view-only) من غير ما نوقف الاتصال.
    try {
      final camStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();
      if (camStatus.isGranted || micStatus.isGranted) {
        _localStream = await navigator.mediaDevices.getUserMedia({
          "video": camStatus.isGranted ? {"facingMode": "user"} : false,
          "audio": micStatus.isGranted,
        });
        _localRenderer.srcObject = _localStream;
      }
    } catch (_) {
      // فشل تجهيز كاميرا/مايك الوالد مش سبب كافي نوقف الاتصال بالكامل
    }

    _connectSignaling();
  }

  Future<void> _loadIceServers() async {
    final servers = await CameraService.fetchIceServers();
    if (!_disposed) {
      _iceServers = servers;
    }
  }

  void _connectSignaling() {
    final wsBase = CameraService.server
        .replaceFirst("https://", "wss://")
        .replaceFirst("http://", "ws://");
    final wsUrl = "$wsBase/signal";

    setState(() => _status = "جاري الاتصال بالسيرفر...");

    WebSocket.connect(wsUrl).then((socket) {
      if (_disposed) {
        socket.close();
        return;
      }

      _ws = socket;
      _reconnectAttempts = 0;

      socket.add(jsonEncode({
        "type": "register",
        "role": "viewer",
        "session": widget.sessionId,
        "adminToken": widget.adminToken,
        "name": "الوالد",
      }));

      socket.listen(
        _onSignalMessage,
        onDone: () {
          if (!mounted) return;
          setState(() => _status = "انقطع الاتصال بالسيرفر - جاري إعادة المحاولة...");
          _cleanupPeerConnection();
          _scheduleReconnect();
        },
        onError: (e) {
          if (!mounted) return;
          setState(() => _status = "خطأ في الاتصال: $e");
          _cleanupPeerConnection();
          _scheduleReconnect();
        },
      );
    }).catchError((e) {
      if (!mounted) return;
      setState(() => _status = "فشل الاتصال بالسيرفر - جاري إعادة المحاولة...");
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectTimer != null) return;

    final delayMs = (300 * math.pow(1.6, _reconnectAttempts)).clamp(300, 4000).toInt();
    _reconnectAttempts++;

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (!_disposed) _connectSignaling();
    });
  }

  Future<void> _onSignalMessage(dynamic raw) async {
    final msg = jsonDecode(raw);

    if (msg["type"] == "auth-failed") {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = "تعذر الاتصال بهذا الجهاز - قد يكون تم نسيانه أو إلغاء اقترانه.";
        });
      }
      _ws?.close();
      return;
    }

    if (msg["type"] == "offer") {
      _broadcasterId = msg["from"].toString();
      await _handleOffer(msg["sdp"]);
      return;
    }

    if (msg["type"] == "ice") {
      final c = msg["candidate"];
      if (_pc != null && c != null) {
        try {
          await _pc!.addCandidate(RTCIceCandidate(
            c["candidate"],
            c["sdpMid"],
            c["sdpMLineIndex"],
          ));
        } catch (_) {}
      }
      return;
    }

    if (msg["type"] == "kicked") {
      _cleanupPeerConnection();
      if (mounted) {
        setState(() {
          _hasRemoteVideo = false;
          _status = "تم إنهاء الاتصال بواسطة صاحب الجهاز";
        });
      }
      return;
    }

    if (msg["type"] == "join-rejected") {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = "تم رفض طلب الاتصال من صاحب الجهاز.";
        });
      }
      return;
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> sdp) async {
    // لو كان فيه اتصال سابق شغال (مثلاً بعد إعادة اتصال)، نقفله الأول
    _cleanupPeerConnection(notify: false);

    final pc = await createPeerConnection({"iceServers": _iceServers});
    _pc = pc;

    _localStream?.getTracks().forEach((track) {
      pc.addTrack(track, _localStream!);
    });

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteRenderer.srcObject = _remoteStream;
        if (mounted) {
          setState(() {
            _hasRemoteVideo = true;
            _connecting = false;
            _status = "متصل";
          });
        }
      }
    };

    pc.onIceCandidate = (candidate) {
      if (_broadcasterId == null) return;
      _ws?.add(jsonEncode({
        "type": "ice",
        "target": _broadcasterId,
        "candidate": {
          "candidate": candidate.candidate,
          "sdpMid": candidate.sdpMid,
          "sdpMLineIndex": candidate.sdpMLineIndex,
        },
      }));
    };

    pc.onConnectionState = (state) {
      if (!mounted) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        setState(() {
          _hasRemoteVideo = false;
          _status = "انقطع الاتصال بالجهاز";
        });
      }
    };

    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp["sdp"], sdp["type"]));
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      _ws?.add(jsonEncode({
        "type": "answer",
        "sdp": {"sdp": answer.sdp, "type": answer.type},
      }));
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = "فشل إنشاء الاتصال: $e";
        });
      }
    }
  }

  void _cleanupPeerConnection({bool notify = true}) {
    try {
      _remoteRenderer.srcObject = null;
    } catch (_) {}
    _pc?.close();
    _pc = null;
    _remoteStream = null;
    if (notify && mounted) {
      setState(() => _hasRemoteVideo = false);
    }
  }

  void _switchRemoteCamera() {
    if (_broadcasterId == null) return;
    _ws?.add(jsonEncode({
      "type": "switch-camera",
      "target": _broadcasterId,
    }));
  }

  void _toggleRemoteMic() {
    if (_broadcasterId == null) return;
    _ws?.add(jsonEncode({
      "type": "toggle-mic",
      "target": _broadcasterId,
    }));
  }

  void _toggleLocalAudio() {
    if (_localStream == null) return;
    setState(() => _localAudioEnabled = !_localAudioEnabled);
    for (final t in _localStream!.getAudioTracks()) {
      t.enabled = _localAudioEnabled;
    }
  }

  void _toggleLocalPreview() {
    setState(() => _showLocalPreview = !_showLocalPreview);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    WakelockPlus.disable();
    _pc?.close();
    _remoteRenderer.srcObject = null;
    _localRenderer.srcObject = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _remoteRenderer.dispose();
    _localRenderer.dispose();
    _ws?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.name),
        centerTitle: true,
        actions: [
          if (_localStream != null)
            IconButton(
              icon: Icon(_localAudioEnabled ? Icons.mic : Icons.mic_off),
              onPressed: _toggleLocalAudio,
              tooltip: _localAudioEnabled ? "كتم مايكي" : "تشغيل مايكي",
            ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: _hasRemoteVideo ? _switchRemoteCamera : null,
            tooltip: "تبديل كاميرا الجهاز",
          ),
          IconButton(
            icon: const Icon(Icons.mic_external_off),
            onPressed: _hasRemoteVideo ? _toggleRemoteMic : null,
            tooltip: "كتم/تشغيل مايك الجهاز",
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            style: const TextStyle(color: Colors.red, fontSize: 16),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _init,
                            icon: const Icon(Icons.refresh),
                            label: const Text("إعادة المحاولة"),
                          ),
                        ],
                      ),
                    ),
                  )
                : _hasRemoteVideo
                    ? Stack(
                        children: [
                          Positioned.fill(
                            child: RTCVideoView(_remoteRenderer),
                          ),
                          if (_showLocalPreview && _localStream != null)
                            Positioned(
                              bottom: 16,
                              right: 16,
                              child: GestureDetector(
                                onTap: _toggleLocalPreview,
                                child: Container(
                                  width: 100,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.white, width: 1.5),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  clipBehavior: Clip.hardEdge,
                                  child: RTCVideoView(_localRenderer, mirror: true),
                                ),
                              ),
                            )
                          else if (_localStream != null)
                            Positioned(
                              bottom: 16,
                              right: 16,
                              child: GestureDetector(
                                onTap: _toggleLocalPreview,
                                child: _pill("إظهار كاميرتي"),
                              ),
                            ),
                        ],
                      )
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(color: Colors.white70),
                            const SizedBox(height: 16),
                            Text(
                              _connecting ? _status : "في انتظار بث الجهاز...",
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey.shade900,
            child: Text(
              _status,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }
}

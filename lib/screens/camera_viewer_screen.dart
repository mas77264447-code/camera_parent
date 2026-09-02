import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/camera_service.dart';

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

class _CameraViewerScreenState extends State<CameraViewerScreen>
    with WidgetsBindingObserver {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _remoteStream;
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  String? _broadcasterId;
  String _status = "جاري الاتصال...";
  bool _remoteAudioMuted = false;

  bool _textureRefreshedForThisTrack = false;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  bool _rejected = false;

  List<Map<String, dynamic>> _iceServers = const [
    {"urls": "stun:stun.l.google.com:19302"},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshRemoteVideoTexture();
    }
  }

  void _refreshRemoteVideoTexture() {
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

  Future<void> _loadIceServers() async {
    final servers = await CameraService.fetchIceServers();
    if (!_disposed) {
      _iceServers = servers;
    }
  }

  Future<void> _init() async {
    await _loadIceServers();

    await _remoteRenderer.initialize();
    await _connectSignaling();
  }

  Future<void> _connectSignaling() async {
    final wsUrl = CameraService.server
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://") +
        "/signal";

    try {
      final socket = await WebSocket.connect(wsUrl);
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
        "name": widget.name,
      }));

      if (mounted) setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");

      socket.listen(
        _onSignalMessage,
        onDone: () {
          if (_rejected) return;
          if (mounted) setState(() => _status = "انقطع الاتصال - جاري إعادة المحاولة...");
          _scheduleReconnect();
        },
        onError: (e) {
          if (mounted) setState(() => _status = "خطأ: $e");
          _scheduleReconnect();
        },
      );
    } catch (e) {
      if (mounted) setState(() => _status = "فشل الاتصال بالسيرفر - جاري إعادة المحاولة...");
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _rejected) return;
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

    if (msg["type"] == "await-approval") {
      if (mounted) setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");
    } else if (msg["type"] == "join-rejected") {
      _rejected = true;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _pc?.close();
      if (mounted) setState(() => _status = "صاحب الكاميرا رفض طلب الاتصال");
    } else if (msg["type"] == "offer") {
      _broadcasterId = msg["from"].toString();

      if (_pc != null) {
        try {
          await _pc!.close();
        } catch (_) {}
        _pc = null;
      }
      _remoteStream = null;
      _textureRefreshedForThisTrack = false;

      _pc = await createPeerConnection({"iceServers": _iceServers});

      _pc!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          if (mounted) setState(() => _status = "متصل");

          if (!_textureRefreshedForThisTrack) {
            _textureRefreshedForThisTrack = true;
            _refreshRemoteVideoTexture();
            Future.delayed(const Duration(milliseconds: 600), () {
              if (mounted && _remoteStream != null) {
                _refreshRemoteVideoTexture();
              }
            });
          }
        }
      };

      _pc!.onIceCandidate = (candidate) {
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

      _pc!.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          try {
            _remoteRenderer.srcObject = null;
          } catch (_) {}
          if (mounted) {
            setState(() => _status = "انقطع الاتصال بجهاز الكاميرا");
          }
        }
      };

      await _pc!.setRemoteDescription(
        RTCSessionDescription(msg["sdp"]["sdp"], msg["sdp"]["type"]),
      );

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      _ws?.add(jsonEncode({
        "type": "answer",
        "sdp": {"sdp": answer.sdp, "type": answer.type},
      }));
    } else if (msg["type"] == "ice") {
      if (_pc != null && msg["candidate"] != null) {
        final c = msg["candidate"];
        await _pc!.addCandidate(RTCIceCandidate(
          c["candidate"],
          c["sdpMid"],
          c["sdpMLineIndex"],
        ));
      }
    }
  }

  void _switchRemoteCamera() {
    if (_broadcasterId == null) return;
    _ws?.add(jsonEncode({
      "type": "switch-camera",
      "target": _broadcasterId,
    }));
  }

  void _toggleRemoteAudio() {
    if (_remoteStream == null) return;
    setState(() => _remoteAudioMuted = !_remoteAudioMuted);
    for (final t in _remoteStream!.getAudioTracks()) {
      t.enabled = !_remoteAudioMuted;
    }
  }


  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _pc?.close();
    _ws?.close();
    _remoteRenderer.dispose();
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
          if (_remoteStream != null)
            IconButton(
              icon: Icon(_remoteAudioMuted ? Icons.volume_off : Icons.volume_up),
              onPressed: _toggleRemoteAudio,
              tooltip: _remoteAudioMuted ? "تشغيل صوت الطفل" : "كتم صوت الطفل",
            ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: _remoteStream != null ? _switchRemoteCamera : null,
            tooltip: "تبديل كاميرا الطفل (أمامية/خلفية)",
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: RTCVideoView(_remoteRenderer)),
                if (_rejected)
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
                              "صاحب الكاميرا رفض طلب الاتصال",
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
              _status,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/camera_service.dart';

const MethodChannel _foregroundServiceChannel =
    MethodChannel('camera_parent/foreground_service');

class CameraStreamScreen extends StatefulWidget {
  final String sessionId;
  final String cameraName;
  final String? childUrl;
  final String? dashboardUrl;

  const CameraStreamScreen({
    super.key,
    required this.sessionId,
    required this.cameraName,
    this.childUrl,
    this.dashboardUrl,
  });

  @override
  State<CameraStreamScreen> createState() => _CameraStreamScreenState();
}

class _CameraStreamScreenState extends State<CameraStreamScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _localStream;
  WebSocket? _ws;
  final Map<String, RTCPeerConnection> _peerConnections = {};

  final Map<String, String> _callerNames = {};
  String? _activeViewerId;

  bool _ready = false;
  String? _error;
  String _status = "جاري التجهيز...";
  bool _usingFrontCamera = false;
  bool _hasRemoteVideo = false;

  static const List<Map<String, dynamic>> _iceServers = [
    {"urls": "stun:stun.l.google.com:19302"},
    {"urls": "turn:openrelay.metered.ca:80", "username": "openrelayproject", "credential": "openrelayproject"},
    {"urls": "turn:openrelay.metered.ca:443", "username": "openrelayproject", "credential": "openrelayproject"},
    {"urls": "turn:openrelay.metered.ca:443?transport=tcp", "username": "openrelayproject", "credential": "openrelayproject"},
  ];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _init();
  }

  Future<void> _init() async {
    final camStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    await Permission.notification.request();

    if (!camStatus.isGranted || !micStatus.isGranted) {
      setState(() {
        _error = "لازم تسمح بصلاحية الكاميرا والميكروفون من إعدادات الموبايل";
      });
      return;
    }

    try {
      await _foregroundServiceChannel.invokeMethod('start');
      await _foregroundServiceChannel.invokeMethod('requestBatteryOptimizationExemption');
    } catch (_) {
      // لو فشل تشغيل الخدمة، البث هيفضل شغال طول ما التطبيق فاتح
    }

    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();

      final stream = await navigator.mediaDevices.getUserMedia({
        "video": {"facingMode": "environment"},
        "audio": true,
      });

      _localStream = stream;
      _localRenderer.srcObject = stream;

      setState(() {
        _ready = true;
        _status = "جاهز - في انتظار مكالمات";
      });

      _connectSignaling();
    } catch (e) {
      setState(() {
        _error = "فشل تشغيل الكاميرا/الميكروفون: $e";
      });
    }
  }

  void _connectSignaling() {
    final wsUrl = CameraService.server
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://") +
        "/signal";

    WebSocket.connect(wsUrl).then((socket) {
      _ws = socket;

      socket.add(jsonEncode({
        "type": "register",
        "role": "broadcaster",
        "session": widget.sessionId,
        "name": widget.cameraName,
      }));

      socket.listen(
        _onSignalMessage,
        onDone: () {
          if (mounted) setState(() => _status = "انقطع الاتصال بالسيرفر");
        },
        onError: (e) {
          if (mounted) setState(() => _status = "خطأ في الاتصال: $e");
        },
      );
    }).catchError((e) {
      if (mounted) setState(() => _status = "فشل الاتصال بالسيرفر: $e");
    });
  }

  Future<void> _onSignalMessage(dynamic raw) async {
    final msg = jsonDecode(raw);

    if (msg["type"] == "viewer-joined") {
      final viewerId = msg["viewerId"].toString();
      final name = (msg["name"] ?? "زائر").toString();

      if (mounted) {
        setState(() {
          _callerNames[viewerId] = name;
        });
      }

      await _createOfferForViewer(viewerId);
    } else if (msg["type"] == "viewer-left") {
      final viewerId = msg["viewerId"].toString();
      _peerConnections[viewerId]?.close();
      _peerConnections.remove(viewerId);

      if (mounted) {
        setState(() {
          _callerNames.remove(viewerId);
          if (_activeViewerId == viewerId) {
            _activeViewerId = null;
            _hasRemoteVideo = false;
          }
          _status = "جاهز - في انتظار مكالمات";
        });
      }
    } else if (msg["type"] == "answer") {
      final viewerId = msg["viewerId"].toString();
      final pc = _peerConnections[viewerId];
      if (pc != null) {
        await pc.setRemoteDescription(
          RTCSessionDescription(msg["sdp"]["sdp"], msg["sdp"]["type"]),
        );
      }
    } else if (msg["type"] == "ice") {
      final fromId = msg["from"].toString();
      final pc = _peerConnections[fromId];
      if (pc != null && msg["candidate"] != null) {
        final c = msg["candidate"];
        await pc.addCandidate(RTCIceCandidate(
          c["candidate"],
          c["sdpMid"],
          c["sdpMLineIndex"],
        ));
      }
    }
  }

  Future<void> _createOfferForViewer(String viewerId) async {
    final pc = await createPeerConnection({"iceServers": _iceServers});
    _peerConnections[viewerId] = pc;

    _localStream?.getTracks().forEach((track) {
      pc.addTrack(track, _localStream!);
    });

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams[0];
        if (mounted) {
          setState(() {
            _hasRemoteVideo = true;
            _activeViewerId = viewerId;
            _status = "شغال - عدد المتصلين: ${_peerConnections.length}";
          });
        }
      }
    };

    pc.onIceCandidate = (candidate) {
      _ws?.add(jsonEncode({
        "type": "ice",
        "target": viewerId,
        "candidate": {
          "candidate": candidate.candidate,
          "sdpMid": candidate.sdpMid,
          "sdpMLineIndex": candidate.sdpMLineIndex,
        },
      }));
    };

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    _ws?.add(jsonEncode({
      "type": "offer",
      "viewerId": viewerId,
      "sdp": {"sdp": offer.sdp, "type": offer.type},
    }));

    if (mounted) {
      setState(() {
        _status = "شغال - عدد المتصلين: ${_peerConnections.length}";
      });
    }
  }

  void _showCallersSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text("الأجهزة المتصلة", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            if (_callerNames.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text("محدش متصل دلوقتي"),
              )
            else
              ..._callerNames.entries.map((entry) {
                final isActive = entry.key == _activeViewerId && _hasRemoteVideo;
                return ListTile(
                  leading: Icon(
                    Icons.circle,
                    size: 12,
                    color: isActive ? Colors.green : Colors.orange,
                  ),
                  title: Text(entry.value),
                  subtitle: Text(isActive ? "متصل - الفيديو شغال" : "بيتصل..."),
                );
              }),
          ],
        ),
      ),
    );
  }

  void _showLinksSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("رابط الكاميرا دي بس:", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            SelectableText(widget.childUrl ?? ""),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.childUrl ?? ""));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("تم نسخ الرابط")),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text("نسخ رابط الكاميرا"),
            ),
            if (widget.dashboardUrl != null) ...[
              const SizedBox(height: 20),
              const Text("رابط لوحة كل الكاميرات:", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              SelectableText(widget.dashboardUrl!),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.dashboardUrl!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("تم نسخ رابط اللوحة")),
                  );
                },
                icon: const Icon(Icons.dashboard),
                label: const Text("نسخ رابط اللوحة"),
              ),
            ],
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 10),
            const Text(
              "لو البث بيقف لما تخرج من التطبيق (خصوصًا في أجهزة Xiaomi/Redmi):",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () {
                _foregroundServiceChannel.invokeMethod('openAutoStartSettings');
              },
              icon: const Icon(Icons.settings),
              label: const Text("فتح إعدادات التشغيل التلقائي"),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchCamera() async {
    if (_localStream == null) return;

    final videoTrack = _localStream!.getVideoTracks().first;
    await Helper.switchCamera(videoTrack);

    setState(() {
      _usingFrontCamera = !_usingFrontCamera;
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _foregroundServiceChannel.invokeMethod('stop').catchError((_) {});
    for (final pc in _peerConnections.values) {
      pc.close();
    }
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _ws?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.cameraName),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Badge(
              label: Text("${_callerNames.length}"),
              isLabelVisible: _callerNames.isNotEmpty,
              child: const Icon(Icons.people),
            ),
            onPressed: _showCallersSheet,
            tooltip: "الأجهزة المتصلة",
          ),
          if (widget.childUrl != null)
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: _showLinksSheet,
              tooltip: "الروابط",
            ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: _ready ? _switchCamera : null,
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
                : !_ready
                    ? const Center(child: CircularProgressIndicator())
                    : _hasRemoteVideo
                        ? Stack(
                            children: [
                              Positioned.fill(
                                child: RTCVideoView(_remoteRenderer),
                              ),
                              Positioned(
                                top: 8,
                                right: 12,
                                child: _pill(
                                  _activeViewerId != null
                                      ? (_callerNames[_activeViewerId] ?? "متصل")
                                      : "متصل",
                                ),
                              ),
                            ],
                          )
                        : RTCVideoView(_localRenderer, mirror: _usingFrontCamera),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.black,
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }
}

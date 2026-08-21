import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/camera_service.dart';

class CameraViewerScreen extends StatefulWidget {
  final String sessionId;
  final String name;

  const CameraViewerScreen({
    super.key,
    required this.sessionId,
    required this.name,
  });

  @override
  State<CameraViewerScreen> createState() => _CameraViewerScreenState();
}

class _CameraViewerScreenState extends State<CameraViewerScreen> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  String? _broadcasterId;
  String _status = "جاري الاتصال...";

  static const List<Map<String, dynamic>> _iceServers = [
    {"urls": "stun:stun.l.google.com:19302"},
    {"urls": "turn:openrelay.metered.ca:80", "username": "openrelayproject", "credential": "openrelayproject"},
    {"urls": "turn:openrelay.metered.ca:443", "username": "openrelayproject", "credential": "openrelayproject"},
    {"urls": "turn:openrelay.metered.ca:443?transport=tcp", "username": "openrelayproject", "credential": "openrelayproject"},
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _remoteRenderer.initialize();

    final wsUrl = CameraService.server
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://") +
        "/signal";

    try {
      final socket = await WebSocket.connect(wsUrl);
      _ws = socket;

      socket.add(jsonEncode({
        "type": "register",
        "role": "viewer",
        "session": widget.sessionId,
      }));

      socket.listen(
        _onSignalMessage,
        onDone: () {
          if (mounted) setState(() => _status = "انقطع الاتصال");
        },
        onError: (e) {
          if (mounted) setState(() => _status = "خطأ: $e");
        },
      );
    } catch (e) {
      setState(() => _status = "فشل الاتصال بالسيرفر: $e");
    }
  }

  Future<void> _onSignalMessage(dynamic raw) async {
    final msg = jsonDecode(raw);

    if (msg["type"] == "offer") {
      _broadcasterId = msg["from"].toString();

      _pc = await createPeerConnection({"iceServers": _iceServers});

      _pc!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteRenderer.srcObject = event.streams[0];
          if (mounted) setState(() => _status = "متصل");
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

  @override
  void dispose() {
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
      ),
      body: Column(
        children: [
          Expanded(child: RTCVideoView(_remoteRenderer)),
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

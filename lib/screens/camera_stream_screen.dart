import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/camera_service.dart';

class CameraStreamScreen extends StatefulWidget {
  final String sessionId;

  const CameraStreamScreen({super.key, required this.sessionId});

  @override
  State<CameraStreamScreen> createState() => _CameraStreamScreenState();
}

class _CameraStreamScreenState extends State<CameraStreamScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _localStream;
  WebSocket? _ws;
  final Map<String, RTCPeerConnection> _peerConnections = {};

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

    if (!camStatus.isGranted || !micStatus.isGranted) {
      setState(() {
        _error = "لازم تسمح بصلاحية الكاميرا والميكروفون من إعدادات الموبايل";
      });
      return;
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
        _status = "جاهز - في انتظار مشاهدين";
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
      await _createOfferForViewer(viewerId);
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
        if (mounted) setState(() => _hasRemoteVideo = true);
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
        _status = "شغال - عدد المشاهدين: ${_peerConnections.length}";
      });
    }
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
        title: const Text("البث شغال"),
        centerTitle: true,
        actions: [
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
                    : Stack(
                        children: [
                          Positioned.fill(
                            child: RTCVideoView(_localRenderer, mirror: _usingFrontCamera),
                          ),
                          if (_hasRemoteVideo)
                            Positioned(
                              bottom: 12,
                              left: 12,
                              width: 110,
                              height: 150,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.white, width: 2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: RTCVideoView(_remoteRenderer),
                                ),
                              ),
                            ),
                        ],
                      ),
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
}

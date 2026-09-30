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
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _remoteStream;
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  String? _broadcasterId;
  String _status = "جاري الاتصال...";
  bool _remoteAudioMuted = false;

  bool _textureRefreshedForThisTrack = false;
  String _requestedSource = "camera";

  Timer? _reconnectTimer;
  Timer? _healthCheckTimer;
  Timer? _pingTimer;
  Timer? _noMediaWatchdog;
  Timer? _diagTimer;
  String _diag = '';

  int _reconnectAttempts = 0;
  int _consecutiveFailures = 0;

  bool _disposed = false;
  bool _rejected = false;

  bool _iceRestartInProgress = false;

  final List<RTCIceCandidate> _pendingRemoteIce = [];
  bool _remoteDescSet = false;

  static const int MAX_CONSECUTIVE_FAILURES = 3;
  static const int MAX_RECONNECT_ATTEMPTS = 20;
  static const Duration NO_MEDIA_TIMEOUT = Duration(seconds: 60);

  List<Map<String, dynamic>> _iceServers = const [
    {"urls": "stun:stun.l.google.com:19302"},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    _diagTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _updateDiag(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshRemoteVideoTexture();
      if (_ws?.readyState != WebSocket.open && !_disposed) {
        debugPrint("[AppLifecycle] resumed - reconnecting");
        _scheduleReconnect();
      }
    }
  }

  String _short(Object? o) => o == null ? '-' : o.toString().split('.').last;

  /// لوحة تشخيص مؤقتة: تبيّن أين ينقطع الفيديو (استقبال/فك ترميز/عرض).
  Future<void> _updateDiag() async {
    if (_disposed || !mounted) return;
    final pc = _pc;
    final lines = <String>[];
    lines.add('pc=${_short(pc?.connectionState)} ice=${_short(pc?.iceConnectionState)}');
    final s = _remoteStream;
    final vt = s?.getVideoTracks();
    lines.add('tracks v=${vt?.length ?? 0} a=${s?.getAudioTracks().length ?? 0}'
        ' enabled=${(vt != null && vt.isNotEmpty) ? vt.first.enabled : '-'}');
    lines.add('renderer=${_remoteRenderer.videoWidth}x${_remoteRenderer.videoHeight}');
    if (pc != null) {
      try {
        final reports = await pc.getStats();
        for (final r in reports) {
          if (r.type != 'inbound-rtp') continue;
          final kind = (r.values['kind'] ?? r.values['mediaType'])?.toString();
          if (kind != 'video') continue;
          lines.add('rx bytes=${r.values['bytesReceived']} pkts=${r.values['packetsReceived']} lost=${r.values['packetsLost']}');
          lines.add('frames rx=${r.values['framesReceived']} dec=${r.values['framesDecoded']} drop=${r.values['framesDropped']}');
          lines.add('size=${r.values['frameWidth']}x${r.values['frameHeight']}');
        }
      } catch (e) {
        lines.add('stats error');
      }
    }
    if (!mounted || _disposed) return;
    setState(() => _diag = lines.join('\n'));
  }

  void _refreshRemoteVideoTexture() {
    final stream = _remoteStream;
    if (stream != null) {
      debugPrint('[Viewer] refreshing texture');
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
    try {
      final servers = await CameraService.fetchIceServers();
      if (!_disposed) {
        setState(() => _iceServers = servers);
        final hasTurn = servers.any((s) {
          if (s['urls'] is String) {
            return (s['urls'] as String).startsWith('turn:');
          }
          if (s['urls'] is List) {
            return (s['urls'] as List)
                .any((u) => u.toString().startsWith('turn:'));
          }
          return false;
        });
        debugPrint("[ICE] loaded ${servers.length} servers, TURN=$hasTurn");
      }
    } catch (e) {
      debugPrint("[ICE] load error: $e");
    }
  }

  Future<void> _chooseRequestedSource() async {
    if (widget.initialSource != null) {
      _requestedSource = widget.initialSource!;
      return;
    }
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("اختر مصدر البث"),
        content: const Text("هل تريد بث الكاميرا أم مشاركة شاشة الجهاز؟"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, "camera"),
            child: const Text("📷 الكاميرا"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, "screen"),
            child: const Text("🖥️ الشاشة"),
          ),
        ],
      ),
    );
    _requestedSource = result ?? "camera";
  }

  Future<void> _init() async {
    await _chooseRequestedSource();
    await _loadIceServers();
    await _remoteRenderer.initialize();
    _startHealthCheck();
    await _connectSignaling();
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) {
        if (_disposed) return;
        _performHealthCheck();
      },
    );
  }

  void _performHealthCheck() {
    final wsState = _ws?.readyState;
    final wsConnected = wsState == WebSocket.open;
    final pcState = _pc?.connectionState;
    final pcConnected = _pc == null ||
        (pcState != RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
            pcState != RTCPeerConnectionState.RTCPeerConnectionStateClosed);
    if (!wsConnected || !pcConnected) {
      _consecutiveFailures++;
      debugPrint("[Health] failures=$_consecutiveFailures");
      if (_consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        _reconnectFull();
      }
    } else {
      _consecutiveFailures = 0;
    }
  }

  void _startNoMediaWatchdog() {
    _noMediaWatchdog?.cancel();
    _noMediaWatchdog = Timer(NO_MEDIA_TIMEOUT, () {
      if (_disposed) return;
      final state = _pc?.connectionState;
      final connected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateConnecting;
      if (connected && _remoteStream == null) {
        debugPrint('[Viewer] no media after ${NO_MEDIA_TIMEOUT.inSeconds}s — restart');
        _tryIceRestart();
      }
    });
  }

  Future<void> _tryIceRestart() async {
    if (_iceRestartInProgress || _disposed) return;
    _iceRestartInProgress = true;

    try {
      if (mounted) setState(() => _status = "إعادة محاولة الاتصال...");
      debugPrint('[ICE] sending request-restart-ice');

      try {
        _ws?.add(jsonEncode({"type": "request-restart-ice"}));
      } catch (e) {
        debugPrint('[ICE] send failed: $e');
        _iceRestartInProgress = false;
        _reconnectFull();
        return;
      }

      _noMediaWatchdog?.cancel();
      _noMediaWatchdog = Timer(const Duration(seconds: 30), () {
        if (_disposed) return;
        if (_remoteStream == null) {
          debugPrint('[ICE] no offer after restart request — full reconnect');
          _reconnectFull();
        }
      });
    } finally {
      _iceRestartInProgress = false;
    }
  }

  void _startPingServer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        if (_disposed || _ws?.readyState != WebSocket.open) return;
        try {
          _ws!.add(jsonEncode({"type": "ping"}));
        } catch (e) {
          debugPrint("[Ping] error: $e");
        }
      },
    );
  }

  Future<void> _connectSignaling() async {
    if (_disposed) return;

    final wsUrl = CameraService.server
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://") +
        "/signal";

    try {
      final socket = await WebSocket.connect(wsUrl).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException("timeout"),
      );

      if (_disposed) {
        socket.close();
        return;
      }

      _ws = socket;
      _consecutiveFailures = 0;
      _reconnectAttempts = 0;

      socket.add(jsonEncode({
        "type": "register",
        "role": "viewer",
        "session": widget.sessionId,
        "adminToken": widget.adminToken,
        "name": widget.name,
        "requestedSource": _requestedSource,
      }));

      if (mounted) {
        setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");
      }

      _startPingServer();

      socket.listen(
        _onSignalMessage,
        onDone: () async {
          if (_rejected) return;
          try { await _pc?.close(); } catch (_) {}
          _pc = null;
          _remoteStream = null;
          _broadcasterId = null;
          _textureRefreshedForThisTrack = false;
          _remoteDescSet = false;
          _pendingRemoteIce.clear();
          _noMediaWatchdog?.cancel();
          _noMediaWatchdog = null;
          try { _remoteRenderer.srcObject = null; } catch (_) {}
          if (mounted) {
            setState(() => _status = "انقطع الاتصال - جاري إعادة المحاولة...");
          }
          _scheduleReconnect();
        },
        onError: (e) {
          if (mounted) setState(() => _status = "خطأ: $e");
          _scheduleReconnect();
        },
      );
    } on TimeoutException {
      if (mounted) {
        setState(() => _status = "انتهت مهلة الاتصال - جاري إعادة المحاولة...");
      }
      _scheduleReconnect();
    } catch (e) {
      if (mounted) {
        setState(() => _status = "فشل الاتصال بالسيرفر - جاري إعادة المحاولة...");
      }
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _rejected) return;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;

    final baseDelay = 3000;
    final maxDelay = 30000;
    final delayMs = (baseDelay * math.pow(1.6, _reconnectAttempts))
        .clamp(baseDelay.toDouble(), maxDelay.toDouble())
        .toInt();

    _reconnectAttempts++;

    if (_reconnectAttempts > MAX_RECONNECT_ATTEMPTS) {
      if (mounted) {
        setState(() => _status = "فشل الاتصال - تم تجاوز الحد الأقصى");
      }
      return;
    }

    debugPrint("[Viewer] reconnect in ${delayMs}ms (attempt $_reconnectAttempts)");

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (!_disposed) _connectSignaling();
    });
  }

  Future<void> _reconnectFull() async {
    if (_disposed) return;

    _rejected = false;
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _pingTimer?.cancel();
    _noMediaWatchdog?.cancel();
    _reconnectTimer = null;
    _noMediaWatchdog = null;

    try { await _pc?.close(); } catch (_) {}
    try { await _ws?.close(); } catch (_) {}

    _pc = null;
    _ws = null;
    _remoteStream = null;
    _broadcasterId = null;
    _textureRefreshedForThisTrack = false;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    _reconnectAttempts = 0;
    _consecutiveFailures = 0;
    try { _remoteRenderer.srcObject = null; } catch (_) {}

    if (mounted) {
      setState(() => _status = "إعادة الاتصال الكاملة...");
    }

    await Future.delayed(const Duration(seconds: 3));

    if (!_disposed) {
      _startHealthCheck();
      await _connectSignaling();
    }
  }

  Future<void> _onSignalMessage(dynamic raw) async {
    try {
      final msg = jsonDecode(raw);
      final type = msg["type"] as String?;

      switch (type) {
        case "await-approval":
          if (mounted) {
            setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");
          }
          break;
        case "viewer-approved":
          if (mounted) {
            setState(() => _status = "تمت الموافقة - جاري الاتصال...");
          }
          break;
        case "join-rejected":
          _rejected = true;
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _noMediaWatchdog?.cancel();
          _noMediaWatchdog = null;
          final oldPc2 = _pc;
          _pc = null;
          if (oldPc2 != null) {
            try { await oldPc2.close(); } catch (_) {}
          }
          if (mounted) {
            setState(() => _status = "صاحب الكاميرا رفض طلب الاتصال");
          }
          break;
        case "offer":
          await _handleOffer(msg);
          break;
        case "broadcaster-left":
          await _handleBroadcasterLeft();
          break;
        case "ice":
          await _handleIceCandidate(msg);
          break;
        case "pong":
          break;
      }
    } catch (e) {
      debugPrint("[Signal] error: $e");
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    final sdp = msg["sdp"];
    if (sdp is! String || sdp.length > 200000) {
      debugPrint("[Offer] invalid or oversized SDP");
      return;
    }

    _broadcasterId = msg["from"].toString();

    // ⚠️ عيّن _pc = null أولًا لمنع callback القديم من إعادة تشغيل الاتصال
    final oldPc = _pc;
    _pc = null;
    if (oldPc != null) {
      try { await oldPc.close(); } catch (_) {}
    }
    _remoteStream = null;
    _textureRefreshedForThisTrack = false;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    try { _remoteRenderer.srcObject = null; } catch (_) {}

    try {
      final pc = await createPeerConnection({"iceServers": _iceServers});
      _pc = pc;

      // ✅✅✅ التعديل: onTrack محسّن
      pc.onTrack = (event) {
        debugPrint('[PC] onTrack received');
        debugPrint('[PC] kind=${event.track.kind}');
        debugPrint('[PC] streams count=${event.streams.length}');

        if (event.streams.isEmpty) {
          debugPrint('[PC] onTrack called but streams is empty!');
          return;
        }

        final stream = event.streams[0];
        debugPrint('[PC] stream id=${stream.id}');
        debugPrint('[PC] video tracks=${stream.getVideoTracks().length}');
        debugPrint('[PC] audio tracks=${stream.getAudioTracks().length}');

        _remoteStream = stream;
        _noMediaWatchdog?.cancel();
        _noMediaWatchdog = null;

        if (mounted) setState(() => _status = "متصل ✓");

        // ✅✅✅ إعادة تعيين renderer بقوة
        _textureRefreshedForThisTrack = true;
        try {
          _remoteRenderer.srcObject = null;
        } catch (_) {}

        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted || _remoteStream == null) return;
          try {
            _remoteRenderer.srcObject = _remoteStream;
            setState(() {});
            debugPrint('[PC] ✅ renderer updated with remote stream');
          } catch (e) {
            debugPrint('[PC] renderer update failed: $e');
          }
        });

        // إعادة إضافية بعد 1.5 ثانية
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (!mounted || _remoteStream == null) return;
          if (_remoteRenderer.srcObject == null) {
            debugPrint('[PC] renderer still null — retrying');
            try {
              _remoteRenderer.srcObject = _remoteStream;
              setState(() {});
            } catch (_) {}
          }
        });
      };

      pc.onIceCandidate = (candidate) {
        try {
          _ws?.add(jsonEncode({
            "type": "ice",
            "target": _broadcasterId,
            "candidate": {
              "candidate": candidate.candidate,
              "sdpMid": candidate.sdpMid,
              "sdpMLineIndex": candidate.sdpMLineIndex,
            },
          }));
        } catch (e) {
          debugPrint("[ICE] send error: $e");
        }
      };

      pc.onConnectionState = (state) {
        debugPrint("[PC] state=$state (current=${_pc == pc})");
        if (_pc != pc) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          debugPrint("[PC] failed — ICE restart only (NOT WS reconnect)");
          _tryIceRestart();
        }
        // Closed يُتجاهل — نحن من أغلقه بأنفسنا
      };

      pc.onIceConnectionState = (state) {
        debugPrint("[ICE] state=$state (current=${_pc == pc})");
        if (_pc != pc) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          debugPrint('[ICE] $state — ICE restart only');
          _tryIceRestart();
        }
      };

      await pc.setRemoteDescription(RTCSessionDescription(sdp, "offer"));

      _remoteDescSet = true;
      for (final c in _pendingRemoteIce) {
        try { await pc.addCandidate(c); } catch (_) {}
      }
      _pendingRemoteIce.clear();

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      _ws?.add(jsonEncode({
        "type": "answer",
        "target": _broadcasterId,
        "sdp": answer.sdp,
      }));

      _startNoMediaWatchdog();
    } catch (e) {
      debugPrint("[Offer] error: $e");
      _scheduleReconnect();
    }
  }

  Future<void> _handleBroadcasterLeft() async {
    try { _remoteRenderer.srcObject = null; } catch (_) {}
    final oldPc = _pc;
    _pc = null;
    if (oldPc != null) {
      try { await oldPc.close(); } catch (_) {}
    }
    _remoteStream = null;
    _broadcasterId = null;
    _textureRefreshedForThisTrack = false;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    _noMediaWatchdog?.cancel();
    _noMediaWatchdog = null;
    if (mounted) {
      setState(() => _status = "انقطع جهاز الطفل - في انتظار عودة البث...");
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> msg) async {
    try {
      if (msg["candidate"] == null) return;
      final c = msg["candidate"];
      final candidate = RTCIceCandidate(
        c["candidate"],
        c["sdpMid"],
        c["sdpMLineIndex"],
      );
      if (_pc == null || !_remoteDescSet) {
        _pendingRemoteIce.add(candidate);
        return;
      }
      await _pc!.addCandidate(candidate);
    } catch (e) {
      debugPrint("[ICE] add error: $e");
    }
  }

  void _switchRemoteCamera() {
    if (_broadcasterId == null) return;
    try {
      _ws?.add(jsonEncode({
        "type": "switch-camera",
        "target": _broadcasterId,
      }));
    } catch (e) {
      debugPrint("[Switch] error: $e");
    }
  }

  void _toggleRemoteAudio() {
    if (_remoteStream == null) return;
    setState(() => _remoteAudioMuted = !_remoteAudioMuted);
    for (final t in _remoteStream!.getAudioTracks()) {
      t.enabled = !_remoteAudioMuted;
    }
  }

  Future<void> _leaveViewerSession() async {
    if (_disposed) return;

    _disposed = true;
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _pingTimer?.cancel();
    _noMediaWatchdog?.cancel();

    final socket = _ws;
    try {
      if (socket != null && socket.readyState == WebSocket.open) {
        socket.add(jsonEncode({"type": "leave-viewer"}));
      }
    } catch (_) {}

    _ws = null;
    try { await _pc?.close(); } catch (_) {}
    _pc = null;
    try { socket?.close(); } catch (_) {}
  }

  Future<bool> _handleBack() async {
    await _leaveViewerSession();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _pingTimer?.cancel();
    _diagTimer?.cancel();
    _noMediaWatchdog?.cancel();

    try {
      if (_ws?.readyState == WebSocket.open) {
        _ws?.add(jsonEncode({"type": "leave-viewer"}));
      }
    } catch (_) {}

    try { _pc?.close(); } catch (_) {}
    try { _ws?.close(); } catch (_) {}
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isScreenShare = _requestedSource == "screen";
    return WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: "رجوع",
            onPressed: () async {
              await _leaveViewerSession();
              if (mounted) Navigator.of(context).pop();
            },
          ),
          title: Text(
            isScreenShare ? '${widget.name} - الشاشة' : widget.name,
          ),
          centerTitle: true,
          actions: [
            if (_remoteStream != null)
              IconButton(
                icon: Icon(
                    _remoteAudioMuted ? Icons.volume_off : Icons.volume_up),
                onPressed: _toggleRemoteAudio,
                tooltip:
                    _remoteAudioMuted ? "تشغيل صوت الطفل" : "كتم صوت الطفل",
              ),
            if (!isScreenShare)
              IconButton(
                icon: const Icon(Icons.cameraswitch),
                onPressed:
                    _remoteStream != null ? _switchRemoteCamera : null,
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
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        color: Colors.black54,
                        child: Text(
                          _diag,
                          style: const TextStyle(
                              color: Colors.greenAccent, fontSize: 10),
                        ),
                      ),
                    ),
                  ),
                  if (isScreenShare && _remoteStream != null)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.red.shade700,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.screen_share,
                                color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text(
                              'بث الشاشة',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
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
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 15),
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
      ),
    );
  }
}
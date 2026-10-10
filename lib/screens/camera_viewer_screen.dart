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
  /// ✅ إن مُرِّر → يتجاهل نافذة الاختيار ويبدأ مباشرة بهذا المصدر.
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
  // ✅ watchdog لاكتشاف "متصل بدون صورة"
  Timer? _noMediaWatchdog;

  int _reconnectAttempts = 0;
  int _consecutiveFailures = 0;

  bool _disposed = false;
  bool _rejected = false;

  // ✅ مرشحات ICE قد تصل قبل ضبط remote description → خزّنها ثم أضفها.
  final List<RTCIceCandidate> _pendingRemoteIce = [];
  bool _remoteDescSet = false;

  static const int MAX_CONSECUTIVE_FAILURES = 2;
  static const int MAX_RECONNECT_ATTEMPTS = 15;

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
      if (_ws?.readyState != WebSocket.open && !_disposed) {
        debugPrint("[AppLifecycle] resumed - reconnecting");
        _scheduleReconnect();
      }
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
    try {
      final servers = await CameraService.fetchIceServers();
      if (!_disposed) {
        setState(() {
          _iceServers = servers;
        });
      }
    } catch (e) {
      debugPrint("[ICE] load error: $e");
    }
  }

  Future<void> _chooseRequestedSource() async {
    // ✅ إذا مُرِّر initialSource → لا نعرض النافذة
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
      const Duration(seconds: 15),
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
      if (_consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        _reconnectFull();
      }
    } else {
      _consecutiveFailures = 0;
    }
  }

  // ✅ إذا مرّت 8 ثوانٍ والـ PC متصل بدون remote stream → إعادة كاملة
  void _startNoMediaWatchdog() {
    _noMediaWatchdog?.cancel();
    _noMediaWatchdog = Timer(const Duration(seconds: 8), () {
      if (_disposed) return;
      final connected = _pc?.connectionState ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      if (connected && _remoteStream == null) {
        debugPrint('[Viewer] connected but no media — full reconnect');
        _reconnectFull();
      }
    });
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
        const Duration(seconds: 10),
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

          // ✅ إغلاق PeerConnection القديمة عند قطع WS
          try {
            await _pc?.close();
          } catch (_) {}
          _pc = null;
          _remoteStream = null;
          _broadcasterId = null;
          _textureRefreshedForThisTrack = false;
          _remoteDescSet = false;
          _pendingRemoteIce.clear();
          _noMediaWatchdog?.cancel();
          _noMediaWatchdog = null;
          try {
            _remoteRenderer.srcObject = null;
          } catch (_) {}

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
        setState(
            () => _status = "انتهت مهلة الاتصال - جاري إعادة المحاولة...");
      }
      _scheduleReconnect();
    } catch (e) {
      if (mounted) {
        setState(
            () => _status = "فشل الاتصال بالسيرفر - جاري إعادة المحاولة...");
      }
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _rejected) return;
    if (_reconnectTimer != null) return;

    final baseDelay = 300;
    final maxDelay = 8000;

    final delayMs = (baseDelay * math.pow(1.5, _reconnectAttempts))
        .clamp(baseDelay.toDouble(), maxDelay.toDouble())
        .toInt();

    _reconnectAttempts++;

    if (_reconnectAttempts > MAX_RECONNECT_ATTEMPTS) {
      if (mounted) {
        setState(() => _status = "فشل الاتصال - تم تجاوز الحد الأقصى");
      }
      return;
    }

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

    await Future.delayed(const Duration(seconds: 2));

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
          try { await _pc?.close(); } catch (_) {}
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

    if (_pc != null) {
      try { await _pc!.close(); } catch (_) {}
      _pc = null;
    }
    _remoteStream = null;
    _textureRefreshedForThisTrack = false;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    try { _remoteRenderer.srcObject = null; } catch (_) {}

    try {
      _pc = await createPeerConnection({"iceServers": _iceServers});

      _pc!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          // ✅ ألغِ watchdog لأن الصورة وصلت
          _noMediaWatchdog?.cancel();
          _noMediaWatchdog = null;
          if (mounted) setState(() => _status = "متصل ✓");

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

      _pc!.onConnectionState = (state) {
        debugPrint("[PC] state=$state");
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          try { _remoteRenderer.srcObject = null; } catch (_) {}
          if (mounted) {
            setState(() => _status = "انقطع الاتصال بجهاز الكاميرا");
          }
          _scheduleReconnect();
        }
      };

      _pc!.onIceConnectionState = (state) {
        debugPrint("[ICE] state=$state");
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          try { _pc?.restartIce(); } catch (_) {}
        }
      };

      await _pc!.setRemoteDescription(
        RTCSessionDescription(sdp, "offer"),
      );

      _remoteDescSet = true;
      for (final c in _pendingRemoteIce) {
        try { await _pc!.addCandidate(c); } catch (_) {}
      }
      _pendingRemoteIce.clear();

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      _ws?.add(jsonEncode({
        "type": "answer",
        "sdp": answer.sdp,
      }));

      // ✅ ابدأ watchdog لاكتشاف "متصل بدون صورة"
      _startNoMediaWatchdog();
    } catch (e) {
      debugPrint("[Offer] error: $e");
      _scheduleReconnect();
    }
  }

  Future<void> _handleBroadcasterLeft() async {
    try { _remoteRenderer.srcObject = null; } catch (_) {}
    try { await _pc?.close(); } catch (_) {}
    _pc = null;
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
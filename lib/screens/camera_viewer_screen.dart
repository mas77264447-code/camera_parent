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

  String _requestedSource = "camera";

  Timer? _reconnectTimer;
  Timer? _healthCheckTimer;
  Timer? _pingTimer;

  int _reconnectAttempts = 0;
  int _consecutiveFailures = 0;

  bool _disposed = false;
  bool _rejected = false;

  // ✅ إصلاح: مرشحات ICE قد تصل قبل ضبط remote description → خزّنها وأضفها لاحقاً.
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
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("اختر مصدر البث"),
        content: const Text("هل تريد بث الكاميرا أم مشاركة شاشة الجهاز؟"),
        actions: [
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.orange),
              tooltip: 'إعادة تشغيل الجهاز',
              onPressed: _sendWakeCommand,
            ),
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
    final pcConnected =
        pcState != RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
            pcState != RTCPeerConnectionState.RTCPeerConnectionStateClosed;

    if (!wsConnected || (_pc != null && !pcConnected)) {
      _consecutiveFailures++;

      if (_consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        _reconnectFull();
      }
    } else {
      _consecutiveFailures = 0;
    }
  }

  void _startPingServer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(seconds: 20),
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
        onDone: () {
          if (_rejected) return;
          if (mounted) {
            setState(
                () => _status = "انقطع الاتصال - جاري إعادة المحاولة...");
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
    _reconnectTimer = null;

    try {
      _pc?.close();
    } catch (_) {}
    try {
      _ws?.close();
    } catch (_) {}

    _pc = null;
    _ws = null;
    _remoteStream = null;
    _broadcasterId = null;
    _textureRefreshedForThisTrack = false;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    _reconnectAttempts = 0;
    _consecutiveFailures = 0;

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

      if (msg["type"] == "await-approval") {
        if (mounted) {
          setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");
        }
      } else if (msg["type"] == "join-rejected") {
        _rejected = true;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _pc?.close();
        if (mounted) {
          setState(() => _status = "صاحب الكاميرا رفض طلب الاتصال");
        }
      } else if (msg["type"] == "offer") {
        await _handleOffer(msg);
      } else if (msg["type"] == "broadcaster-left") {
        await _handleBroadcasterLeft();
      } else if (msg["type"] == "ice") {
        await _handleIceCandidate(msg);
      } else if (msg["type"] == "pong") {
        // silent
      }
    } catch (e) {
      debugPrint("[Signal] error: $e");
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    // ✅ الإصلاح: تحقق من حجم SDP قبل المعالجة
    final sdp = msg["sdp"];
    if (sdp is! String || sdp.length > 200000) {
      debugPrint("[Offer] invalid or oversized SDP");
      return;
    }

    _broadcasterId = msg["from"].toString();

    if (_pc != null) {
      try {
        await _pc!.close();
      } catch (_) {}
      _pc = null;
    }
    _remoteStream = null;
    _textureRefreshedForThisTrack = false;
    // اتصال جديد: صفّر حالة remote description والمرشحات المؤقتة.
    _remoteDescSet = false;
    _pendingRemoteIce.clear();

    try {
      _pc = await createPeerConnection({"iceServers": _iceServers});

      _pc!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
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
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          try {
            _remoteRenderer.srcObject = null;
          } catch (_) {}
          if (mounted) {
            setState(() => _status = "انقطع الاتصال بجهاز الكاميرا");
          }
          _scheduleReconnect();
        }
      };

      await _pc!.setRemoteDescription(
        RTCSessionDescription(sdp, "offer"),
      );

      // ✅ الآن remote description جاهز: فرّغ المرشحات المخزّنة مؤقتاً.
      _remoteDescSet = true;
      for (final c in _pendingRemoteIce) {
        try {
          await _pc!.addCandidate(c);
        } catch (_) {}
      }
      _pendingRemoteIce.clear();

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      _ws?.add(jsonEncode({
        "type": "answer",
        "sdp": answer.sdp,
      }));
    } catch (e) {
      debugPrint("[Offer] error: $e");
      _scheduleReconnect();
    }
  }

  Future<void> _handleBroadcasterLeft() async {
    try {
      _remoteRenderer.srcObject = null;
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    _remoteStream = null;
    _broadcasterId = null;
    // ✅ الإصلاح: صفّر علم الـ texture
    _textureRefreshedForThisTrack = false;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
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

      // ✅ إصلاح: خزّن المرشح إذا لم يجهز الاتصال/remote description بعد.
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

    final socket = _ws;
    try {
      if (socket != null && socket.readyState == WebSocket.open) {
        socket.add(jsonEncode({"type": "leave-viewer"}));
      }
    } catch (_) {}

    _ws = null;

    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    try {
      socket?.close();
    } catch (_) {}
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

    try {
      if (_ws?.readyState == WebSocket.open) {
        _ws?.add(jsonEncode({"type": "leave-viewer"}));
      }
    } catch (_) {}

    try {
      _pc?.close();
    } catch (_) {}
    try {
      _ws?.close();
    } catch (_) {}
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _sendWakeCommand() {
    if (_ws == null || _ws!.readyState != WebSocket.open) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الاتصال بالسيرفر غير جاهز'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    try {
      _ws!.add(jsonEncode({'type': 'wake'}));
      setState(() => _status = 'تم إرسال أمر الإيقاظ...');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ تم إرسال أمر إعادة التشغيل'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      debugPrint('[Wake] error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
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
          title: Text(widget.name),
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

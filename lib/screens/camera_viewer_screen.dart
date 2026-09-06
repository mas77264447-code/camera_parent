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
  Timer? _healthCheckTimer;
  Timer? _pingTimer;
  
  int _reconnectAttempts = 0;
  int _failureCount = 0;
  int _consecutiveFailures = 0;
  
  bool _disposed = false;
  bool _rejected = false;
  
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
      // أعد الاتصال إذا كان قد انقطع أثناء السكون
      if (_ws?.readyState != WebSocket.open && !_disposed) {
        print("[AppLifecycle] تم استئناف التطبيق - إعادة الاتصال");
        _scheduleReconnect();
      }
    } else if (state == AppLifecycleState.paused) {
      print("[AppLifecycle] تم إيقاف التطبيق مؤقتاً");
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
          print("[ICE] تم تحميل ${servers.length} خادم ICE");
        });
      }
    } catch (e) {
      print("[ICE] خطأ في تحميل خوادم ICE: $e");
      // استخدم الخوادم الافتراضية
    }
  }

  Future<void> _init() async {
    await _loadIceServers();
    await _remoteRenderer.initialize();
    
    // ابدأ مراقبة صحة الاتصال
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
    print("[HealthCheck] بدء مراقبة الاتصال كل 15 ثانية");
  }

  void _performHealthCheck() {
    // تحقق من حالة WebSocket
    final wsState = _ws?.readyState;
    final wsConnected = wsState == WebSocket.open;
    
    // تحقق من حالة Peer Connection
    final pcState = _pc?.connectionState;
    final pcConnected = pcState != RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
                        pcState != RTCPeerConnectionState.RTCPeerConnectionStateClosed;
    
    print("[HealthCheck] WS: ${wsState ?? 'null'}, PC: ${pcState ?? 'null'}, "
          "Remote: ${_remoteStream != null ? 'yes' : 'no'}");
    
    if (!wsConnected || (_pc != null && !pcConnected)) {
      _consecutiveFailures++;
      print("[HealthCheck] فشل متتالي #$_consecutiveFailures");
      
      if (_consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        print("[HealthCheck] بدء إعادة اتصال كاملة بعد $MAX_CONSECUTIVE_FAILURES محاولات فاشلة");
        _reconnectFull();
      }
    } else {
      _consecutiveFailures = 0;
    }
  }

  void _startPingServer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) {
        if (_disposed || _ws?.readyState != WebSocket.open) return;
        
        try {
          _ws!.add(jsonEncode({"type": "ping"}));
        } catch (e) {
          print("[Ping] خطأ: $e");
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

    print("[WS] محاولة الاتصال بـ: $wsUrl");

    try {
      final socket = await WebSocket.connect(
        wsUrl,
        // أضف timeout للاتصال
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException("فشل الاتصال - timeout"),
      );
      
      if (_disposed) {
        socket.close();
        return;
      }

      _ws = socket;
      _consecutiveFailures = 0;
      _reconnectAttempts = 0;
      
      print("[WS] تم الاتصال بنجاح");

      socket.add(jsonEncode({
        "type": "register",
        "role": "viewer",
        "session": widget.sessionId,
        "adminToken": widget.adminToken,
        "name": widget.name,
      }));

      if (mounted) {
        setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");
      }

      _startPingServer();

      socket.listen(
        _onSignalMessage,
        onDone: () {
          if (_rejected) return;
          print("[WS] تم قطع الاتصال من السيرفر");
          if (mounted) setState(() => _status = "انقطع الاتصال - جاري إعادة المحاولة...");
          _scheduleReconnect();
        },
        onError: (e) {
          print("[WS] خطأ في الاتصال: $e");
          if (mounted) setState(() => _status = "خطأ: $e");
          _scheduleReconnect();
        },
      );
    } on TimeoutException catch (e) {
      print("[WS] انتهت مهلة الاتصال: $e");
      if (mounted) setState(() => _status = "انتهت مهلة الاتصال - جاري إعادة المحاولة...");
      _scheduleReconnect();
    } catch (e) {
      print("[WS] فشل الاتصال: $e");
      if (mounted) setState(() => _status = "فشل الاتصال بالسيرفر - جاري إعادة المحاولة...");
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _rejected) return;
    if (_reconnectTimer != null) return;

    // استخدم exponential backoff مع حد أقصى
    final baseDelay = 300;
    final maxDelay = 8000;
    
    final delayMs = (baseDelay * math.pow(1.5, _reconnectAttempts))
        .clamp(baseDelay.toDouble(), maxDelay.toDouble())
        .toInt();
    
    _reconnectAttempts++;

    if (_reconnectAttempts > MAX_RECONNECT_ATTEMPTS) {
      print("[Reconnect] تم تجاوز الحد الأقصى للمحاولات ($_reconnectAttempts)");
      if (mounted) {
        setState(() => _status = "فشل الاتصال - تم تجاوز الحد الأقصى للمحاولات");
      }
      return;
    }

    print("[Reconnect] محاولة #$_reconnectAttempts بعد ${delayMs}ms");

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (!_disposed) _connectSignaling();
    });
  }

  Future<void> _reconnectFull() async {
    if (_disposed) return;

    print("[Reconnect] إعادة اتصال كاملة");

    _disposed = false;
    _rejected = false;
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _pingTimer?.cancel();

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
        if (mounted) setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");
      } else if (msg["type"] == "join-rejected") {
        _rejected = true;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _pc?.close();
        if (mounted) setState(() => _status = "صاحب الكاميرا رفض طلب الاتصال");
      } else if (msg["type"] == "offer") {
        await _handleOffer(msg);
      } else if (msg["type"] == "broadcaster-left") {
        await _handleBroadcasterLeft();
      } else if (msg["type"] == "ice") {
        await _handleIceCandidate(msg);
      } else if (msg["type"] == "pong") {
        print("[Ping] استقبال pong من السيرفر");
      }
    } catch (e) {
      print("[Signal] خطأ في معالجة الرسالة: $e");
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    _broadcasterId = msg["from"].toString();

    if (_pc != null) {
      try {
        await _pc!.close();
      } catch (_) {}
      _pc = null;
    }
    _remoteStream = null;
    _textureRefreshedForThisTrack = false;

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
          print("[ICE] خطأ في إرسال ICE: $e");
        }
      };

      _pc!.onConnectionState = (state) {
        print("[PC] حالة الاتصال: $state");
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
        RTCSessionDescription(msg["sdp"] as String, "offer"),
      );

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      _ws?.add(jsonEncode({
        "type": "answer",
        "sdp": answer.sdp,
      }));
    } catch (e) {
      print("[Offer] خطأ في معالجة العرض: $e");
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
    if (mounted) {
      setState(() => _status = "انقطع جهاز الطفل - في انتظار عودة البث...");
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> msg) async {
    try {
      if (_pc != null && msg["candidate"] != null) {
        final c = msg["candidate"];
        await _pc!.addCandidate(RTCIceCandidate(
          c["candidate"],
          c["sdpMid"],
          c["sdpMLineIndex"],
        ));
      }
    } catch (e) {
      print("[ICE] خطأ في إضافة ICE: $e");
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
      print("[Switch] خطأ: $e");
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
        socket.add(jsonEncode({
          "type": "leave-viewer",
        }));
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

    try { _pc?.close(); } catch (_) {}
    try { _ws?.close(); } catch (_) {}
    _remoteRenderer.dispose();
    super.dispose();
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
      ),
    );
  }
}

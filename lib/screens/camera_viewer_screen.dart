import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import '../services/camera_service.dart';
import '../services/connection_state_manager.dart';
import '../services/stream_watchdog.dart';
import 'received_files_screen.dart';
import 'recovery_diagnostics_screen.dart';

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
  static const int _maxIncomingTransferBytes = 25 * 1024 * 1024;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _remoteStream;
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  String? _broadcasterId;
  String _status = "جاري الاتصال...";
  bool _remoteAudioMuted = false;

  bool _textureRefreshedForThisTrack = false;
  final List<RTCIceCandidate> _pendingIceCandidates = <RTCIceCandidate>[];
  int _socketGeneration = 0;
  bool _remoteDescriptionSet = false;
  bool _reconnectInFlight = false;

  // المصدر اللي هنطلبه من جهاز الطفل: "camera" أو "screen". بيتحدد من
  // المستخدم (الوالد) قبل ما نتصل، وبيتبعت مع طلب التسجيل عشان الطفل
  // يعرف يعرض نوع الطلب في نافذة الموافقة بتاعته.
  String _requestedSource = "camera";

  Timer? _reconnectTimer;
  Timer? _healthCheckTimer;
  Timer? _pingTimer;
  
  int _reconnectAttempts = 0;
  int _failureCount = 0;
  int _consecutiveFailures = 0;
  final StreamWatchdog _watchdog = StreamWatchdog();
  
  bool _disposed = false;
  bool _rejected = false;
  
  static const int MAX_CONSECUTIVE_FAILURES = 2;

  List<Map<String, dynamic>> _iceServers = const [
    {"urls": "stun:stun.l.google.com:19302"},
  ];

  final Map<String, _IncomingTransfer> _incomingTransfers = {};

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

  // اسأل الوالد قبل الاتصال: عايز يشوف الكاميرا ولا شاشة جهاز الطفل؟
  // الاختيار ده بيتبعت مع طلب التسجيل (requestedSource) عشان جهاز
  // الطفل يعرضه في نافذة الموافقة ويجهّز المصدر المطلوب بعد الموافقة.
  Future<void> _chooseRequestedSource() async {
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
    
    // ابدأ مراقبة صحة الاتصال
    _startHealthCheck();
    
    await _connectSignaling();
  }

  void _startHealthCheck() {
    _watchdog.start(
      interval: const Duration(seconds: 15),
      healthCheck: () {
        if (_disposed) return true;
        return _performHealthCheck();
      },
      onUnhealthy: () {
        if (!_disposed) unawaited(_reconnectFull());
      },
    );
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    print("[HealthCheck] بدء مراقبة الاتصال كل 15 ثانية");
  }

  bool _performHealthCheck() {
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
      ConnectionStateManager.instance.update(ConnectionStatus.reconnecting, detail: 'viewer health check');
      print("[HealthCheck] فشل متتالي #$_consecutiveFailures");
      
      if (_consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        print("[HealthCheck] بدء إعادة اتصال كاملة بعد $MAX_CONSECUTIVE_FAILURES محاولات فاشلة");
        unawaited(_reconnectFull());
      }
      return false;
    } else {
      _consecutiveFailures = 0;
      _watchdog.markHealthy();
      ConnectionStateManager.instance.update(ConnectionStatus.connected, detail: 'viewer healthy');
      return true;
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

    final generation = ++_socketGeneration;
    try {
      final socket = await WebSocket.connect(
        wsUrl,
        // أضف timeout للاتصال
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException("فشل الاتصال - timeout"),
      );
      
      if (_disposed || generation != _socketGeneration) {
        socket.close();
        return;
      }

      final oldSocket = _ws;
      _ws = socket;
      if (oldSocket != null && oldSocket != socket) {
        try { await oldSocket.close(); } catch (_) {}
      }
      _consecutiveFailures = 0;
      _reconnectAttempts = 0;
      
      print("[WS] تم الاتصال بنجاح");

      socket.add(jsonEncode({
        "type": "register",
        "role": "viewer",
        "session": widget.sessionId,
        "adminToken": widget.adminToken,
        "name": widget.name,
        "viewerKey": widget.sessionId,
        "requestedSource": _requestedSource,
      }));

      if (mounted) {
        setState(() => _status = "في انتظار موافقة صاحب الكاميرا...");
      }

      _startPingServer();

      socket.listen(
        _onSignalMessage,
        onDone: () {
          if (_rejected || generation != _socketGeneration || !identical(_ws, socket)) return;
          _ws = null;
          print("[WS] تم قطع الاتصال من السيرفر");
          if (mounted) setState(() => _status = "انقطع الاتصال - جاري إعادة المحاولة...");
          _scheduleReconnect();
        },
        onError: (e) {
          if (generation != _socketGeneration || !identical(_ws, socket)) return;
          _ws = null;
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
    final baseDelay = 500;
    final maxDelay = 15000;
    final exponent = math.min(_reconnectAttempts, 5);
    final delayMs = (baseDelay * math.pow(2, exponent))
        .clamp(baseDelay.toDouble(), maxDelay.toDouble())
        .toInt();
    
    _reconnectAttempts++;

    print("[Reconnect] محاولة #$_reconnectAttempts بعد ${delayMs}ms");

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (!_disposed) _connectSignaling();
    });
  }

  Future<void> _reconnectFull() async {
    if (_disposed || _reconnectInFlight || _rejected) return;
    _reconnectInFlight = true;

    print("[Reconnect] إعادة اتصال كاملة");
    ConnectionStateManager.instance.update(ConnectionStatus.reconnecting, detail: 'full viewer recovery');

    _rejected = false;
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _pingTimer?.cancel();
    _watchdog.stop();
    _pendingIceCandidates.clear();
    _remoteDescriptionSet = false;
    _socketGeneration++;

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
    _pendingIceCandidates.clear();
    _remoteDescriptionSet = false;
    _textureRefreshedForThisTrack = false;
    _reconnectAttempts = 0;
    _consecutiveFailures = 0;

    if (mounted) {
      setState(() => _status = "إعادة الاتصال الكاملة...");
    }

    await Future.delayed(const Duration(seconds: 2));

    try {
      if (!_disposed) {
        _startHealthCheck();
        await _connectSignaling();
      }
    } finally {
      _reconnectInFlight = false;
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
        _pc = null;
        _pendingIceCandidates.clear();
        if (mounted) setState(() => _status = "صاحب الكاميرا رفض طلب الاتصال");
      } else if (msg["type"] == "offer") {
        await _handleOffer(msg);
      } else if (msg["type"] == "broadcaster-left") {
        await _handleBroadcasterLeft();
      } else if (msg["type"] == "ice") {
        await _handleIceCandidate(msg);
      } else if (msg["type"] == "pong") {
        print("[Ping] استقبال pong من السيرفر");
      } else if (msg["type"] == "permission-response") {
        final granted = msg['granted'] == true;
        if (mounted) {
          setState(() {
            _status = granted
                ? 'تمت الموافقة على الطلب — بانتظار اختيار المحتوى على جهاز Camera...'
                : (msg['error']?.toString() ?? 'تم رفض طلب المحتوى');
          });
        }
      } else if (msg["type"] == "file-transfer-start") {
        _startIncomingTransfer(msg);
      } else if (msg["type"] == "file-transfer-chunk") {
        _appendIncomingTransfer(msg);
      } else if (msg["type"] == "file-transfer-end") {
        await _finishIncomingTransfer(msg);
      }
    } catch (e) {
      print("[Signal] خطأ في معالجة الرسالة: $e");
    }
  }

  void _requestDeviceContent(String kind) {
    if (_ws?.readyState != WebSocket.open) {
      if (mounted) setState(() => _status = 'الاتصال بجهاز Camera غير متاح');
      return;
    }
    final requestId = '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';
    _ws!.add(jsonEncode({
      'type': 'permission-request',
      'requestId': requestId,
      'kind': kind,
    }));
    final label = switch (kind) {
      'gallery_photo' => 'صورة من المعرض',
      'gallery_video' => 'فيديو من المعرض',
      _ => 'ملف',
    };
    if (mounted) setState(() => _status = 'تم إرسال طلب: $label');
  }

  void _startIncomingTransfer(Map<String, dynamic> msg) {
    final requestId = msg['requestId']?.toString();
    if (requestId == null) return;
    final size = (msg['size'] as num?)?.toInt() ?? 0;
    if (size < 0 || size > _maxIncomingTransferBytes) {
      if (mounted) setState(() => _status = 'تم رفض ملف أكبر من الحد المسموح (25 ميجابايت)');
      return;
    }
    _incomingTransfers[requestId] = _IncomingTransfer(
      name: msg['name']?.toString() ?? 'file',
      size: size,
      chunks: <List<int>>[],
    );
    if (mounted) setState(() => _status = 'جاري استلام ${msg['name'] ?? 'الملف'}...');
  }

  void _appendIncomingTransfer(Map<String, dynamic> msg) {
    final requestId = msg['requestId']?.toString();
    final data = msg['data']?.toString();
    if (requestId == null || data == null) return;
    final transfer = _incomingTransfers[requestId];
    if (transfer == null) return;
    try {
      final bytes = base64Decode(data);
      final received = transfer.chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      if (received + bytes.length > _maxIncomingTransferBytes || received + bytes.length > transfer.size) {
        _incomingTransfers.remove(requestId);
        if (mounted) setState(() => _status = 'تم إيقاف استلام ملف تجاوز الحجم المعلن');
        return;
      }
      transfer.chunks.add(bytes);
    } catch (_) {}
  }

  Future<void> _finishIncomingTransfer(Map<String, dynamic> msg) async {
    final requestId = msg['requestId']?.toString();
    if (requestId == null) return;
    final transfer = _incomingTransfers.remove(requestId);
    if (transfer == null) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeName = transfer.name.replaceAll(RegExp(r'[\\/:*?\"<>|]'), '_');
      final file = File('${dir.path}/received_${DateTime.now().millisecondsSinceEpoch}_$safeName');
      final sink = file.openWrite();
      for (final chunk in transfer.chunks) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      if (mounted) {
        setState(() => _status = 'تم استلام ${transfer.name} ✓');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حفظ ${transfer.name} داخل ملفات التطبيق')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'تعذر حفظ الملف: $e');
    }
  }

  Future<void> _openReceivedFiles() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ReceivedFilesScreen()),
    );
  }

  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    final broadcasterId = msg["from"]?.toString();
    final sdp = msg["sdp"]?.toString();
    if (broadcasterId == null || sdp == null || _disposed) return;

    _broadcasterId = broadcasterId;

    final oldPc = _pc;
    if (oldPc != null) {
      try { await oldPc.close(); } catch (_) {}
    }
    _pc = null;
    _remoteStream = null;
    _textureRefreshedForThisTrack = false;

    try {
      final pc = await createPeerConnection({"iceServers": _iceServers});
      _pc = pc;

      pc.onTrack = (event) {
        if (event.streams.isNotEmpty && identical(_pc, pc)) {
          _remoteStream = event.streams[0];
          if (mounted) setState(() => _status = "متصل ✓");

          if (!_textureRefreshedForThisTrack) {
            _textureRefreshedForThisTrack = true;
            _refreshRemoteVideoTexture();
            Future.delayed(const Duration(milliseconds: 600), () {
              if (mounted && identical(_pc, pc) && _remoteStream != null) {
                _refreshRemoteVideoTexture();
              }
            });
          }
        }
      };

      pc.onIceCandidate = (candidate) {
        if (!identical(_pc, pc) || _ws?.readyState != WebSocket.open) return;
        try {
          _ws!.add(jsonEncode({
            "type": "ice",
            "target": broadcasterId,
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

      pc.onConnectionState = (state) {
        print("[PC] حالة الاتصال: $state");
        if (!identical(_pc, pc) || _disposed) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _consecutiveFailures = 0;
          _watchdog.markHealthy();
          ConnectionStateManager.instance.update(ConnectionStatus.connected, detail: 'webrtc connected');
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          try { _remoteRenderer.srcObject = null; } catch (_) {}
          if (mounted) setState(() => _status = "انقطع الاتصال بجهاز Camera - جاري الاستعادة...");
          unawaited(_reconnectFull());
        }
      };

      pc.onIceConnectionState = (state) {
        print("[ICE] حالة الاتصال: $state");
        if (!identical(_pc, pc) || _disposed) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          ConnectionStateManager.instance.update(ConnectionStatus.reconnecting, detail: 'ICE degraded');
          unawaited(_reconnectFull());
        }
      };

      await pc.setRemoteDescription(
        RTCSessionDescription(sdp, "offer"),
      );
      _remoteDescriptionSet = true;

      // ICE can arrive immediately after the offer. Keep early candidates
      // queued until the remote description exists, then apply them.
      final queued = List<RTCIceCandidate>.from(_pendingIceCandidates);
      _pendingIceCandidates.clear();
      for (final candidate in queued) {
        try { await pc.addCandidate(candidate); } catch (_) {}
      }

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      if (_ws?.readyState == WebSocket.open && identical(_pc, pc)) {
        _ws!.add(jsonEncode({
          "type": "answer",
          "sdp": answer.sdp,
        }));
      }
    } catch (e) {
      print("[Offer] خطأ في معالجة العرض: $e");
      try { await _pc?.close(); } catch (_) {}
      _pc = null;
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
    _pendingIceCandidates.clear();
    if (mounted) {
      setState(() => _status = "انقطع جهاز Camera - جاري انتظار عودة الاتصال...");
    }
    unawaited(_reconnectFull());
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> msg) async {
    try {
      final c = msg["candidate"];
      if (c is! Map) return;
      final candidate = RTCIceCandidate(
        c["candidate"] as String?,
        c["sdpMid"] as String?,
        c["sdpMLineIndex"] as int?,
      );

      final pc = _pc;
      if (pc == null || !_remoteDescriptionSet) {
        _pendingIceCandidates.add(candidate);
        return;
      }

      try {
        await pc.addCandidate(candidate);
      } catch (_) {
        _pendingIceCandidates.add(candidate);
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
    _watchdog.stop();

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
    _watchdog.stop();
    _pendingIceCandidates.clear();
    _watchdog.stop();

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
            IconButton(
              icon: const Icon(Icons.health_and_safety_outlined),
              tooltip: 'تشخيص الاتصال وRecovery',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RecoveryDiagnosticsScreen(),
                  ),
                );
              },
            ),
            if (_remoteStream != null)
              IconButton(
                icon: Icon(_remoteAudioMuted ? Icons.volume_off : Icons.volume_up),
                onPressed: _toggleRemoteAudio,
                tooltip: _remoteAudioMuted ? "تشغيل صوت الطفل" : "كتم صوت الطفل",
              ),
            IconButton(
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: _openReceivedFiles,
              tooltip: 'الملفات المستلمة',
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


class _IncomingTransfer {
  final String name;
  final int size;
  final List<List<int>> chunks;

  _IncomingTransfer({required this.name, required this.size, required this.chunks});
}

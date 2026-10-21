import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'camera_service.dart';

/// يدير كل منطق الاتصال (إشارة WebSocket + WebRTC + المراقبات/إعادة
/// الاتصال) لشاشة مشاهدة الأب، بمعزل عن واجهة المستخدم.
///
/// الشاشة (`CameraViewerScreen`) تستمع لهذا الكائن عبر [ChangeNotifier]
/// وتعرض فقط ما يحمله من حالة — لا منطق شبكة/WebRTC داخل الواجهة نفسها.
class ViewerConnectionController extends ChangeNotifier {
  ViewerConnectionController({
    required this.sessionId,
    required this.name,
    required this.adminToken,
    this.initialSource,
  });

  final String sessionId;
  final String name;
  final String adminToken;
  final String? initialSource;

  static const int maxConsecutiveFailures = 3;
  static const int maxReconnectAttempts = 20;
  static const Duration noMediaTimeout = Duration(seconds: 60);

  // ═══ حالة عامة تقرأها الواجهة ═══
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  MediaStream? get remoteStream => _remoteStream;
  String get status => _status;
  String get diag => _diag;
  bool get rejected => _rejected;
  bool get remoteAudioMuted => _remoteAudioMuted;
  bool get isScreenShare => _requestedSource == 'screen';

  MediaStream? _remoteStream;
  String _status = 'جاري الاتصال...';
  String _diag = '';
  bool _rejected = false;
  bool _remoteAudioMuted = false;
  String _requestedSource = 'camera';

  // ═══ إشارة (signaling) ═══
  WebSocket? _ws;
  RTCPeerConnection? _pc;
  String? _broadcasterId;
  bool _remoteDescSet = false;
  final List<RTCIceCandidate> _pendingRemoteIce = [];

  List<Map<String, dynamic>> _iceServers = const [
    {'urls': 'stun:stun.l.google.com:19302'},
  ];

  // ═══ مؤقّتات ═══
  Timer? _reconnectTimer;
  Timer? _healthCheckTimer;
  Timer? _pingTimer;
  Timer? _noMediaWatchdog;
  Timer? _diagTimer;
  Timer? _rendererBindTimer;
  Timer? _videoFrameWatchdog;

  int _videoStallChecks = 0;
  bool _stallIceRestartTried = false;
  int _reconnectAttempts = 0;
  int _consecutiveFailures = 0;
  bool _iceRestartInProgress = false;

  bool _disposed = false;

  // ─────────────────────────── دورة الحياة ───────────────────────────

  /// يبدأ التهيئة الكاملة: اختيار المصدر، تحميل خوادم ICE، تهيئة الـrenderer،
  /// بدء فحص الصحة الدوري، ثم الاتصال بسيرفر الإشارة.
  ///
  /// [chooseSource] تُستدعى فقط إن لم يُحدَّد [initialSource] مسبقاً — تسمح
  /// للواجهة بعرض حوار اختيار المصدر دون أن يعرف هذا الكائن شيئاً عن الـUI.
  Future<void> start({required Future<String?> Function() chooseSource}) async {
    _requestedSource = initialSource ?? await chooseSource() ?? 'camera';
    await _loadIceServers();
    await remoteRenderer.initialize();
    _startHealthCheck();
    _diagTimer = Timer.periodic(const Duration(seconds: 2), (_) => _updateDiag());
    await _connectSignaling();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _pingTimer?.cancel();
    _diagTimer?.cancel();
    _noMediaWatchdog?.cancel();
    _cancelRendererTimers();

    try {
      if (_ws?.readyState == WebSocket.open) {
        _ws?.add(jsonEncode({'type': 'leave-viewer'}));
      }
    } catch (_) {}

    try {
      _pc?.close();
    } catch (_) {}
    try {
      _ws?.close();
    } catch (_) {}
    remoteRenderer.dispose();
    super.dispose();
  }

  /// يُستدعى من `didChangeAppLifecycleState` في الواجهة عند استئناف التطبيق.
  void onAppResumed() {
    _refreshRemoteVideoTexture();
    if (_ws?.readyState != WebSocket.open && !_disposed) {
      debugPrint('[AppLifecycle] resumed - reconnecting');
      _scheduleReconnect();
    }
  }

  Future<void> leaveSession() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _healthCheckTimer?.cancel();
    _pingTimer?.cancel();
    _noMediaWatchdog?.cancel();
    _cancelRendererTimers();

    final socket = _ws;
    try {
      if (socket != null && socket.readyState == WebSocket.open) {
        socket.add(jsonEncode({'type': 'leave-viewer'}));
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

  // ─────────────────────────── أوامر المستخدم ───────────────────────────

  void switchRemoteCamera() {
    if (_broadcasterId == null) return;
    try {
      _ws?.add(jsonEncode({'type': 'switch-camera', 'target': _broadcasterId}));
    } catch (e) {
      debugPrint('[Switch] error: $e');
    }
  }

  void toggleRemoteAudio() {
    if (_remoteStream == null) return;
    _remoteAudioMuted = !_remoteAudioMuted;
    for (final t in _remoteStream!.getAudioTracks()) {
      t.enabled = !_remoteAudioMuted;
    }
    notifyListeners();
  }

  // ─────────────────────────── تشخيص ───────────────────────────

  String _short(Object? o) => o == null ? '-' : o.toString().split('.').last;

  /// لوحة تشخيص مؤقتة: تبيّن أين ينقطع الفيديو (استقبال/فك ترميز/عرض).
  Future<void> _updateDiag() async {
    if (_disposed) return;
    final pc = _pc;
    final lines = <String>[];
    lines.add('pc=${_short(pc?.connectionState)} ice=${_short(pc?.iceConnectionState)}');
    final s = _remoteStream;
    final vt = s?.getVideoTracks();
    lines.add('tracks v=${vt?.length ?? 0} a=${s?.getAudioTracks().length ?? 0}'
        ' enabled=${(vt != null && vt.isNotEmpty) ? vt.first.enabled : '-'}');
    lines.add('renderer=${remoteRenderer.videoWidth}x${remoteRenderer.videoHeight}');
    if (pc != null) {
      try {
        final reports = await pc.getStats();
        var sawVideo = false;
        for (final r in reports) {
          if (r.type != 'inbound-rtp') continue;
          final kind = (r.values['kind'] ?? r.values['mediaType'])?.toString();
          if (kind != 'video') continue;
          sawVideo = true;
          lines.add('rx bytes=${r.values['bytesReceived']} pkts=${r.values['packetsReceived']} lost=${r.values['packetsLost']}');
          lines.add('frames rx=${r.values['framesReceived']} dec=${r.values['framesDecoded']} drop=${r.values['framesDropped']}');
          lines.add('size=${r.values['frameWidth']}x${r.values['frameHeight']}');
        }
        if (!sawVideo) {
          lines.add('rx: NO video inbound-rtp (reports=${reports.length})');
        }
      } catch (e) {
        lines.add('stats error');
      }
    }
    if (_disposed) return;
    _diag = lines.join('\n');
    notifyListeners();
  }

  // ─────────────────────────── ربط الـrenderer ───────────────────────────

  /// يربط الـstream بالـrenderer مرة واحدة فقط (debounce) حتى لو وصل onTrack
  /// للصوت ثم للفيديو، ثم يراقب وصول أول إطار فيديو فعلي.
  void _bindRemoteStream(MediaStream stream) {
    _rendererBindTimer?.cancel();
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}

    _rendererBindTimer = Timer(const Duration(milliseconds: 150), () {
      if (_disposed || !identical(_remoteStream, stream)) return;
      try {
        remoteRenderer.srcObject = stream;
        notifyListeners();
        debugPrint('[Viewer] renderer bound to stream ${stream.id}');
      } catch (e) {
        debugPrint('[Viewer] renderer bind failed: $e');
      }
      _startVideoFrameWatchdog();
    });
  }

  /// إذا الفيديو موجود لكن الـrenderer ما زال 0x0:
  /// - بعد ~4 ثواني يعيد الربط.
  /// - بعد ~10 ثواني يطلب إعادة ICE مرة واحدة.
  /// - بعد ~30 ثانية (إذا بقي 0x0 رغم إعادة ICE) يطلب إعادة اتصال كاملة،
  ///   لأن إعادة ICE وحدها لا تجبر الابن على إعادة فتح الكاميرا — فقط
  ///   إعادة اتصال كاملة تمر بمسار قبول مشاهد جديد عنده تفعل ذلك.
  void _startVideoFrameWatchdog() {
    _videoFrameWatchdog?.cancel();
    _videoStallChecks = 0;
    _stallIceRestartTried = false;

    _videoFrameWatchdog = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      final stream = _remoteStream;
      if (stream == null) {
        timer.cancel();
        return;
      }
      if (stream.getVideoTracks().isEmpty) return;

      if (remoteRenderer.videoWidth > 0) {
        debugPrint('[Watchdog] video OK ${remoteRenderer.videoWidth}x${remoteRenderer.videoHeight}');
        timer.cancel();
        return;
      }

      _videoStallChecks++;
      debugPrint('[Watchdog] renderer still 0x0 (check $_videoStallChecks)');

      if (_videoStallChecks == 2) {
        try {
          remoteRenderer.srcObject = null;
          Future.delayed(const Duration(milliseconds: 100), () {
            if (_disposed || !identical(_remoteStream, stream)) return;
            try {
              remoteRenderer.srcObject = stream;
              notifyListeners();
            } catch (_) {}
          });
        } catch (_) {}
      } else if (_videoStallChecks == 5 && !_stallIceRestartTried) {
        _stallIceRestartTried = true;
        debugPrint('[Watchdog] no video frames after ~10s — ICE restart');
        _tryIceRestart();
      } else if (_videoStallChecks >= 15) {
        timer.cancel();
        debugPrint('[Watchdog] still no video after ~30s despite ICE restart — full reconnect');
        _reconnectFull();
      }
    });
  }

  void _cancelRendererTimers() {
    _rendererBindTimer?.cancel();
    _rendererBindTimer = null;
    _videoFrameWatchdog?.cancel();
    _videoFrameWatchdog = null;
  }

  void _refreshRemoteVideoTexture() {
    final stream = _remoteStream;
    if (stream == null) return;
    debugPrint('[Viewer] refreshing texture');
    remoteRenderer.srcObject = null;
    Future.microtask(() {
      if (_disposed) return;
      remoteRenderer.srcObject = stream;
      notifyListeners();
    });
  }

  // ─────────────────────────── إشارة (WebSocket) ───────────────────────────

  Future<void> _loadIceServers() async {
    try {
      final servers = await CameraService.fetchIceServers();
      if (_disposed) return;
      _iceServers = servers;
      final hasTurn = servers.any((s) {
        if (s['urls'] is String) return (s['urls'] as String).startsWith('turn:');
        if (s['urls'] is List) {
          return (s['urls'] as List).any((u) => u.toString().startsWith('turn:'));
        }
        return false;
      });
      debugPrint('[ICE] loaded ${servers.length} servers, TURN=$hasTurn');
    } catch (e) {
      debugPrint('[ICE] load error: $e');
    }
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_disposed) return;
      _performHealthCheck();
    });
  }

  void _performHealthCheck() {
    final wsConnected = _ws?.readyState == WebSocket.open;
    final pcState = _pc?.connectionState;
    final pcConnected = _pc == null ||
        (pcState != RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
            pcState != RTCPeerConnectionState.RTCPeerConnectionStateClosed);
    if (!wsConnected || !pcConnected) {
      _consecutiveFailures++;
      debugPrint('[Health] failures=$_consecutiveFailures');
      if (_consecutiveFailures >= maxConsecutiveFailures) {
        _reconnectFull();
      }
    } else {
      _consecutiveFailures = 0;
    }
  }

  void _startNoMediaWatchdog() {
    _noMediaWatchdog?.cancel();
    _noMediaWatchdog = Timer(noMediaTimeout, () {
      if (_disposed) return;
      final state = _pc?.connectionState;
      final connected = state == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnecting;
      if (connected && _remoteStream == null) {
        debugPrint('[Viewer] no media after ${noMediaTimeout.inSeconds}s — restart');
        _tryIceRestart();
      }
    });
  }

  Future<void> _tryIceRestart() async {
    if (_iceRestartInProgress || _disposed) return;
    _iceRestartInProgress = true;

    try {
      _status = 'إعادة محاولة الاتصال...';
      notifyListeners();
      debugPrint('[ICE] sending request-restart-ice');

      try {
        _ws?.add(jsonEncode({'type': 'request-restart-ice'}));
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
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_disposed || _ws?.readyState != WebSocket.open) return;
      try {
        _ws!.add(jsonEncode({'type': 'ping'}));
      } catch (e) {
        debugPrint('[Ping] error: $e');
      }
    });
  }

  Future<void> _connectSignaling() async {
    if (_disposed) return;

    final wsUrl = CameraService.server
            .replaceFirst('https://', 'wss://')
            .replaceFirst('http://', 'ws://') +
        '/signal';

    try {
      final socket = await WebSocket.connect(wsUrl).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('timeout'),
      );

      if (_disposed) {
        socket.close();
        return;
      }

      _ws = socket;
      _consecutiveFailures = 0;
      _reconnectAttempts = 0;

      socket.add(jsonEncode({
        'type': 'register',
        'role': 'viewer',
        'session': sessionId,
        'adminToken': adminToken,
        'name': name,
        'requestedSource': _requestedSource,
      }));

      _status = 'في انتظار موافقة صاحب الكاميرا...';
      notifyListeners();

      _startPingServer();

      socket.listen(
        _onSignalMessage,
        onDone: () async {
          if (_rejected) return;
          _cancelRendererTimers();
          try {
            await _pc?.close();
          } catch (_) {}
          _pc = null;
          _remoteStream = null;
          _broadcasterId = null;
          _remoteDescSet = false;
          _pendingRemoteIce.clear();
          _noMediaWatchdog?.cancel();
          _noMediaWatchdog = null;
          try {
            remoteRenderer.srcObject = null;
          } catch (_) {}
          _status = 'انقطع الاتصال - جاري إعادة المحاولة...';
          notifyListeners();
          _scheduleReconnect();
        },
        onError: (e) {
          _status = 'خطأ: $e';
          notifyListeners();
          _scheduleReconnect();
        },
      );
    } on TimeoutException {
      _status = 'انتهت مهلة الاتصال - جاري إعادة المحاولة...';
      notifyListeners();
      _scheduleReconnect();
    } catch (e) {
      _status = 'فشل الاتصال بالسيرفر - جاري إعادة المحاولة...';
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _rejected) return;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;

    const baseDelay = 3000;
    const maxDelay = 30000;
    final delayMs = (baseDelay * math.pow(1.6, _reconnectAttempts))
        .clamp(baseDelay.toDouble(), maxDelay.toDouble())
        .toInt();

    _reconnectAttempts++;

    if (_reconnectAttempts > maxReconnectAttempts) {
      _status = 'فشل الاتصال - تم تجاوز الحد الأقصى';
      notifyListeners();
      return;
    }

    debugPrint('[Viewer] reconnect in ${delayMs}ms (attempt $_reconnectAttempts)');

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

    try {
      await _pc?.close();
    } catch (_) {}
    try {
      await _ws?.close();
    } catch (_) {}

    _pc = null;
    _ws = null;
    _remoteStream = null;
    _broadcasterId = null;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    _reconnectAttempts = 0;
    _consecutiveFailures = 0;
    _cancelRendererTimers();
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}

    _status = 'إعادة الاتصال الكاملة...';
    notifyListeners();

    await Future.delayed(const Duration(seconds: 3));

    if (!_disposed) {
      _startHealthCheck();
      await _connectSignaling();
    }
  }

  // ─────────────────────────── رسائل الإشارة ───────────────────────────

  Future<void> _onSignalMessage(dynamic raw) async {
    try {
      final msg = jsonDecode(raw);
      final type = msg['type'] as String?;

      switch (type) {
        case 'await-approval':
          _status = 'في انتظار موافقة صاحب الكاميرا...';
          notifyListeners();
          break;
        case 'viewer-approved':
          _status = 'تمت الموافقة - جاري الاتصال...';
          notifyListeners();
          break;
        case 'join-rejected':
          _rejected = true;
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _noMediaWatchdog?.cancel();
          _noMediaWatchdog = null;
          final oldPc = _pc;
          _pc = null;
          if (oldPc != null) {
            try {
              await oldPc.close();
            } catch (_) {}
          }
          _status = 'صاحب الكاميرا رفض طلب الاتصال';
          notifyListeners();
          break;
        case 'offer':
          await _handleOffer(msg);
          break;
        case 'broadcaster-left':
          await _handleBroadcasterLeft();
          break;
        case 'ice':
          await _handleIceCandidate(msg);
          break;
        case 'pong':
          break;
      }
    } catch (e) {
      debugPrint('[Signal] error: $e');
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    final sdp = msg['sdp'];
    if (sdp is! String || sdp.length > 200000) {
      debugPrint('[Offer] invalid or oversized SDP');
      return;
    }

    _broadcasterId = msg['from'].toString();

    // ⚠️ عيّن _pc = null أولاً لمنع callback القديم من إعادة تشغيل الاتصال
    final oldPc = _pc;
    _pc = null;
    if (oldPc != null) {
      try {
        await oldPc.close();
      } catch (_) {}
    }
    _remoteStream = null;
    _cancelRendererTimers();
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}

    try {
      final pc = await createPeerConnection({'iceServers': _iceServers});
      _pc = pc;

      pc.onTrack = (event) {
        if (_pc != pc) return; // callback قديم من اتصال سابق
        debugPrint('[PC] onTrack kind=${event.track.kind} streams=${event.streams.length}');

        if (event.streams.isEmpty) {
          debugPrint('[PC] onTrack called but streams is empty!');
          return;
        }

        final stream = event.streams[0];
        debugPrint('[PC] stream id=${stream.id} '
            'video=${stream.getVideoTracks().length} audio=${stream.getAudioTracks().length}');

        _remoteStream = stream;
        _noMediaWatchdog?.cancel();
        _noMediaWatchdog = null;

        _status = 'متصل ✓';
        notifyListeners();

        _bindRemoteStream(stream);
      };

      pc.onIceCandidate = (candidate) {
        try {
          _ws?.add(jsonEncode({
            'type': 'ice',
            'target': _broadcasterId,
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          }));
        } catch (e) {
          debugPrint('[ICE] send error: $e');
        }
      };

      pc.onConnectionState = (state) {
        debugPrint('[PC] state=$state (current=${_pc == pc})');
        if (_pc != pc) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          debugPrint('[PC] failed — ICE restart only (NOT WS reconnect)');
          _tryIceRestart();
        }
        // Closed يُتجاهل — نحن من أغلقه بأنفسنا
      };

      pc.onIceConnectionState = (state) {
        debugPrint('[ICE] state=$state (current=${_pc == pc})');
        if (_pc != pc) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          debugPrint('[ICE] $state — ICE restart only');
          _tryIceRestart();
        }
      };

      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

      _remoteDescSet = true;
      for (final c in _pendingRemoteIce) {
        try {
          await pc.addCandidate(c);
        } catch (_) {}
      }
      _pendingRemoteIce.clear();

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      _ws?.add(jsonEncode({
        'type': 'answer',
        'target': _broadcasterId,
        'sdp': answer.sdp,
      }));

      _startNoMediaWatchdog();
    } catch (e) {
      debugPrint('[Offer] error: $e');
      _scheduleReconnect();
    }
  }

  Future<void> _handleBroadcasterLeft() async {
    _cancelRendererTimers();
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}
    final oldPc = _pc;
    _pc = null;
    if (oldPc != null) {
      try {
        await oldPc.close();
      } catch (_) {}
    }
    _remoteStream = null;
    _broadcasterId = null;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    _noMediaWatchdog?.cancel();
    _noMediaWatchdog = null;
    _status = 'انقطع جهاز الطفل - في انتظار عودة البث...';
    notifyListeners();
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> msg) async {
    try {
      if (msg['candidate'] == null) return;
      final c = msg['candidate'];
      final candidate = RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']);
      if (_pc == null || !_remoteDescSet) {
        _pendingRemoteIce.add(candidate);
        return;
      }
      await _pc!.addCandidate(candidate);
    } catch (e) {
      debugPrint('[ICE] add error: $e');
    }
  }
}

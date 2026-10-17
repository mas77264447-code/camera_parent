import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_service.dart';
import 'connection_state_manager.dart';
import 'file_access_service.dart';
import 'screen_capture_service.dart';
import 'crypto_service.dart';
import 'fcm_service.dart';

/// يراقب عودة واجهة التطبيق للمقدمة لإعادة فتح الكاميرا إذا فُتحت وهي في الخلفية.
class _StreamLifecycleObserver with WidgetsBindingObserver {
  _StreamLifecycleObserver(this._onResumed, this._onBackgrounded);
  final Future<void> Function() _onResumed;
  final void Function() _onBackgrounded;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    } else if (state == AppLifecycleState.paused) {
      _onBackgrounded();
    }
  }
}

/// طلب كاميرا وصل والتطبيق في الخلفية، وينتظر فتح التطبيق.
class _AwaitingViewer {
  _AwaitingViewer(this.name, this.source);
  final String name;
  final String source;
}

class StreamService {
  StreamService._();
  static final StreamService instance = StreamService._();

  bool _running = false;
  bool get running => _running;

  String? _deviceToken;
  String? _sessionId;
  String _cameraName = 'جهاز الطفل';

  WebSocket? _ws;
  bool _wsConnecting = false;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _authFailed = false;
  DateTime? _authFailedAt;
  Timer? _pingTimer;
  int _consecutivePingFailures = 0;

  MediaStream? localStream;
  bool _broadcastScreen = false;
  bool _broadcastFiles = false;

  // ✅ الحفاظ على الشاشة حية حتى بعد انتهاء المشاهدة
  bool _keepScreenStreamAlive = true;
  DateTime? _screenStreamStartedAt;
  // ✅ إيقاف تلقائي بعد 12 ساعة (حماية)
  final Duration _screenAutoStopAfter = const Duration(hours: 12);
  Timer? _screenAutoStopTimer;

  // ── مراقبة الكاميرا (إعادة تشغيلها لو توقفت) ──
  Timer? _cameraWatchdog;
  bool _restartingCamera = false;
  int _cameraRestartAttempts = 0;
  DateTime? _lastCameraRestartAt;
  num? _lastVideoBytesSent;
  int _stalledProbes = 0;

  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, String> _callerNames = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, List<RTCIceCandidate>> _pendingRemoteIceByViewer = {};
  final Set<String> _approvalInFlight = <String>{};
  final Set<String> _offerInFlight = <String>{};
  final Set<String> _recoveringViewers = <String>{};
  final Map<String, int> _videoRecoveryAttempts = <String, int>{};
  bool _cameraAcquiredInBackground = false;
  _StreamLifecycleObserver? _lifecycleObserver;
  final Set<String> _approvedFileViewers = <String>{};

  // مشاهدون وافق عليهم الطفل فعلياً في هذه الجلسة (في الذاكرة فقط،
  // تُفرغ عند إعادة تشغيل التطبيق). أي طلب بعدها يحتاج موافقة جديدة.
  final Set<String> _consentedViewers = <String>{};

  final Set<String> _canceledDownloads = <String>{};

  String? _activeViewerId;
  bool _hasRemoteVideo = false;

  final Map<String, String> _pendingViewers = {};

  bool _autoApproveViewers = true;

  /// الجلسة التي وافق الطفل عليها مرة واحدة على الأقل. تُحفظ في التخزين
  /// ليبقى الإذن بعد إعادة التشغيل، فلا يحتاج الطفل نافذة موافقة لا تظهر.
  String? _trustedSessionId;

  bool _remoteAudioMuted = false;
  bool _localMicMuted = false;
  bool _usingFrontCamera = false;

  // حالة الانتظار لفتح الكاميرا بعد إحضار التطبيق للمقدمة
  bool _pendingCameraStart = false;

  /// الطلبات التي وصلت والتطبيق في الخلفية (لا تُوافَق إلا بعد فتح الكاميرا).
  final Map<String, _AwaitingViewer> _awaitingForeground = {};
  bool _foregroundRequestInFlight = false;
  String? _deferredViewerId;
  String? _deferredCallerName;

  String _status = "جاري التجهيز...";
  String? _error;
  bool _canRetry = false;

  List<Map<String, dynamic>> _iceServers = const [
    {"urls": "stun:stun.l.google.com:19302"},
  ];

  bool _foregroundServiceStarted = false;
  String? _lastCloseInfo;
  bool _storagePermissionChecked = false;
  bool _storagePermissionGranted = false;
  bool _storagePermissionRequested = false;

  final _statusCtrl = StreamController<String>.broadcast();
  final _callersCtrl = StreamController<Map<String, String>>.broadcast();
  final _remoteCtrl = StreamController<Map<String, MediaStream>>.broadcast();
  final _pendingCtrl = StreamController<Map<String, String>>.broadcast();
  final _mediaCtrl = StreamController<MediaStream?>.broadcast();
  final _localStreamCtrl = StreamController<MediaStream?>.broadcast();
  final _fileRequestCtrl = StreamController<Map<String, dynamic>>.broadcast();

  Stream<String> get onStatus => _statusCtrl.stream;
  Stream<Map<String, String>> get onCallers => _callersCtrl.stream;
  Stream<Map<String, MediaStream>> get onRemoteStreams => _remoteCtrl.stream;
  Stream<Map<String, String>> get onPendingRequests => _pendingCtrl.stream;
  Stream<MediaStream?> get onRemoteMedia => _mediaCtrl.stream;
  Stream<MediaStream?> get onLocalStream => _localStreamCtrl.stream;
  Stream<Map<String, dynamic>> get onFileRequest => _fileRequestCtrl.stream;

  String get status => _status;
  String? get error => _error;
  bool get canRetry => _canRetry;
  bool get hasRemoteVideo => _hasRemoteVideo;
  bool get broadcastScreen => _broadcastScreen;
  bool get broadcastFiles => _broadcastFiles;
  bool get remoteAudioMuted => _remoteAudioMuted;
  bool get usingFrontCamera => _usingFrontCamera;
  bool get isScreenStreamAlive => _broadcastScreen && localStream != null;
  MediaStream? get activeRemoteStream =>
      _activeViewerId != null ? _remoteStreams[_activeViewerId] : null;
  String? get activeViewerId => _activeViewerId;
  String? get activeCallerName =>
      _activeViewerId != null ? _callerNames[_activeViewerId] : null;
  Map<String, String> get callers => Map.unmodifiable(_callerNames);
  Map<String, String> get pendingViewers => Map.unmodifiable(_pendingViewers);

  Future<void> start({
    required String sessionId,
    required String deviceToken,
    required String cameraName,
  }) async {
    if (_running &&
        _sessionId == sessionId &&
        _deviceToken == deviceToken) {
      debugPrint('[StreamService] already running');
      _statusCtrl.add(_status);

      // إصلاح: إذا كان التطبيق في المقدمة والكاميرا غير مفعّلة، شغّلها فوراً.
      // يعالج حالة فتح التطبيق يدوياً بعد الإقلاع بينما الـ FGS يعمل بالفعل.
      try {
        final lifecycleState = WidgetsBinding.instance.lifecycleState;
        if (lifecycleState == AppLifecycleState.resumed &&
            localStream == null &&
            !_broadcastScreen &&
            !_broadcastFiles) {
          debugPrint('[StreamService] start(): foreground + no camera -> '
              'triggering _startMediaSource');
          _pendingCameraStart = true;
          unawaited(_startMediaSource().then((_) async {
            final deferredId = _deferredViewerId;
            final deferredName = _deferredCallerName ?? 'Unknown';
            _deferredViewerId = null;
            _deferredCallerName = null;
            _pendingCameraStart = false;
            if (deferredId != null &&
                localStream != null &&
                _hasLiveVideoTrack()) {
              await _sendOfferTo(deferredId, deferredName);
            }
          }).catchError((e) {
            debugPrint('[StreamService] foreground camera start failed: $e');
          }));
        }
      } catch (e) {
        debugPrint('[StreamService] foreground camera start check failed: $e');
      }
      return;
    }

    if (_running) await stop();

    _authFailed = false;
    _sessionId = sessionId;
    _deviceToken = deviceToken;
    _cameraName = cameraName;
    _running = true;

    if (_lifecycleObserver == null) {
      try {
        _lifecycleObserver = _StreamLifecycleObserver(_onAppResumed, _onAppBackgrounded);
        WidgetsBinding.instance.addObserver(_lifecycleObserver!);
        // البدء البارد: قد يكون التطبيق في المقدمة قبل إضافة المراقب، فلا يحدث انتقال
        // إلى resumed. نستأنف الكاميرا المعلّقة يدوياً بعد أول إطار.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_running &&
              _pendingCameraStart &&
              WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
            unawaited(_onAppResumed());
          }
        });
      } catch (e) {
        debugPrint('[StreamService] lifecycle observer failed: $e');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    // أول مرة: الكاميرا تحتاج موافقة الطفل. بعد أول موافقة يُحفظ true
    // (في approvePendingViewer) فتصبح الطلبات التالية مقبولة تلقائياً.
    _autoApproveViewers = prefs.getBool('auto_approve_viewers') ?? false;
    _trustedSessionId = prefs.getString('trusted_session_id');

    _updateStatus("جاري الاتصال بالسيرفر...");
    ConnectionStateManager.instance.update(ConnectionStatus.connecting);

    if (!_foregroundServiceStarted) {
      try {
        const fsChannel = MethodChannel('camera_parent/foreground_service');
        await fsChannel.invokeMethod('start', {'mode': 'camera'});
        const batChannel = MethodChannel('camera_parent/battery_optimization');
        await batChannel.invokeMethod('requestBatteryOptimizationExemption');
        await _requestOverlayPermissionOnce(batChannel);
        _foregroundServiceStarted = true;
      } catch (e) {
        debugPrint('[StreamService] fgs start failed: $e');
      }
      // طلب استثناء البطارية منفصل: فشله لا يجب أن يؤثر على تشغيل الخدمة
      try {
        const batChannel = MethodChannel('camera_parent/battery_optimization');
        await batChannel.invokeMethod('requestBatteryOptimizationExemption');
      } catch (e) {
        debugPrint('[StreamService] battery exemption failed: $e');
      }
    }

    unawaited(_requestStoragePermissionsOnce());

    try {
      _iceServers = await CameraService.fetchIceServers();
    } catch (_) {}

    _startCameraWatchdog();
    await _connectWebSocket();
  }

  /// أندرويد يمنع الكاميرا من الخلفية بدون واجهة ظاهرة، فيتصل المشاهد بصورة سوداء.
  /// نطلب مرة واحدة إذن "العرض فوق التطبيقات" ليتمكن إشعار التنبيه من فتح الواجهة.
  Future<void> _requestOverlayPermissionOnce(MethodChannel channel) async {
    try {
      final has = await channel.invokeMethod<bool>('hasOverlayPermission') ?? true;
      if (has) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('overlay_permission_asked') ?? false) return;
      await prefs.setBool('overlay_permission_asked', true);
      await channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      debugPrint('[StreamService] overlay permission request failed: $e');
    }
  }

  /// عند الانتقال للخلفية: Android يسحب الكاميرا، فيبقى الـ track حياً بلا إطارات.
  /// نعلّم أن الكاميرا تحتاج إعادة اكتساب عند العودة.
  void _onAppBackgrounded() {
    if (localStream != null && !_broadcastScreen && !_broadcastFiles) {
      _cameraAcquiredInBackground = true;
    }
  }

  /// عند عودة التطبيق للمقدمة: إذا كانت الكاميرا في انتظار الفتح، افتحها الآن.
  Future<void> _onAppResumed() async {
    if (!_running) return;
    // ✅ إذا انقطع WS أثناء الخلفية (المؤقتات قد تتجمد)، أعد الاتصال فورًا عند العودة
    if (_ws == null || _ws!.readyState != WebSocket.open) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempts = 0;
      unawaited(_connectWebSocket());
    }
    if (_broadcastScreen || _broadcastFiles) return;

    // إصلاح: إذا كان هناك مشاهد معلّق، اعتبر الكاميرا "معلّقة"
    // حتى لو صُفّر _pendingCameraStart في مكان آخر.
    if (localStream == null && _deferredViewerId != null) {
      _pendingCameraStart = true;
    }

    // إذا كانت هناك محاولة فتح معلّقة، نفّذها الآن
    if (_pendingCameraStart && localStream == null) {
      debugPrint('[StreamService] app resumed — starting pending camera');
      _pendingCameraStart = false;
      await Future.delayed(const Duration(milliseconds: 500));
      if (!_running) return;

      await _startMediaSource();
      if (localStream == null) return;

      // fix: use deferred viewer instead of empty _peerConnections
      final deferredId = _deferredViewerId;
      final deferredName = _deferredCallerName ?? 'Unknown';
      _deferredViewerId = null;
      _deferredCallerName = null;

      if (deferredId != null) {
        final old = _peerConnections.remove(deferredId);
        _pendingRemoteIceByViewer.remove(deferredId);
        try {
          await old?.close();
        } catch (_) {}
        if (!_running) return;
        if (localStream != null && _hasLiveVideoTrack()) {
          await _sendOfferTo(deferredId, deferredName);
        }
      }
      return;
    }

    if (!_cameraAcquiredInBackground) return;
    _cameraAcquiredInBackground = false;
    debugPrint('[StreamService] app resumed — camera was opened in background, re-acquiring');

    await Future.delayed(const Duration(milliseconds: 600));
    if (!_running) return;

    if (_peerConnections.isEmpty) {
      await _forceCleanupStream();
      await _startMediaSource();
    } else {
      await refreshAllViewers();
    }
  }

  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _pingTimer?.cancel();
    _pingTimer = null;
    _consecutivePingFailures = 0;
    _screenAutoStopTimer?.cancel();
    _screenAutoStopTimer = null;
    _cameraWatchdog?.cancel();
    _cameraWatchdog = null;
    _cameraRestartAttempts = 0;

    // ✅ تصفير حالات الانتظار
    _pendingCameraStart = false;
    _foregroundRequestInFlight = false;
    _deferredViewerId = null;
    _awaitingForeground.clear();
    _deferredCallerName = null;

    try { await _ws?.close(); } catch (_) {}
    _ws = null;

    await _closeAllPeerConnections();
    _consentedViewers.clear();
    await _forceCleanupStream();

    _updateStatus('متوقف');
    ConnectionStateManager.instance.update(ConnectionStatus.idle);
  }

  /// ✅ إغلاق PeerConnections فقط (مع الحفاظ على الشاشة إن كانت حية)
  Future<void> _closeAllPeerConnections() async {
    final pcs = List<RTCPeerConnection>.from(_peerConnections.values);
    _peerConnections.clear();
    _callerNames.clear();
    _remoteStreams.clear();
    _pendingRemoteIceByViewer.clear();
    _approvalInFlight.clear();
    _offerInFlight.clear();
    _recoveringViewers.clear();
    _approvedFileViewers.clear();
    _activeViewerId = null;
    _hasRemoteVideo = false;
    _callersCtrl.add({});
    _remoteCtrl.add({});
    _mediaCtrl.add(null);

    for (final pc in pcs) {
      try { await pc.close(); } catch (_) {}
    }
  }

  /// ✅ إغلاق الشاشة بالقوة (فقط عند unpair أو stop)
  Future<void> _forceCleanupStream() async {
    _screenAutoStopTimer?.cancel();
    _screenAutoStopTimer = null;
    _screenStreamStartedAt = null;

    final old = localStream;
    localStream = null;
    _broadcastScreen = false;
    _broadcastFiles = false;
    if (old != null) {
      for (final t in old.getTracks()) {
        try { await t.stop(); } catch (_) {}
      }
      try { await old.dispose(); } catch (_) {}
    }
    _localStreamCtrl.add(null);
  }

  void _startCameraDiag() {
    int tick = 0;
    Timer.periodic(const Duration(seconds: 1), (t) async {
      tick++;
      final s = localStream;
      final tracks = s == null ? const [] : s.getVideoTracks();
      final info = tracks.isEmpty
          ? 'none'
          : tracks.map((x) => 'enabled=${x.enabled} id=${x.id}').join(',');
      _clog('diag t=$tick stream=${s == null ? "null" : "exists"} video=[$info] ws=${_ws?.readyState} wsClosed=${_lastCloseInfo != null} fg=${WidgetsBinding.instance.lifecycleState}');
      if (tick % 3 == 0) {
        for (final entry in _peerConnections.entries) {
          try {
            final reports = await entry.value.getStats();
            int encoded = -1;
            for (final r in reports) {
              if (r.type != 'outbound-rtp') continue;
              final kind = (r.values['kind'] ?? r.values['mediaType'])?.toString();
              if (kind != 'video') continue;
              encoded = int.tryParse('${r.values['framesEncoded'] ?? 0}'.split('.').first) ?? 0;
            }
            _clog('diag frames viewer=${entry.key} encoded=$encoded pc=${entry.value.connectionState}');
          } catch (e) {
            _clog('diag frames error=$e');
          }
        }
      }
      if (tick >= 60) t.cancel();
    });
  }

  void _clog(String message) {
    debugPrint('[StreamService] $message');
    try {
      if (_ws != null && _ws!.readyState == WebSocket.open) {
        _ws!.add(jsonEncode({'type': 'client-log', 'message': message}));
      }
    } catch (_) {}
  }

  /// ✅ معدّلة: لا تفتح الكاميرا في الخلفية (مثلاً عند الإقلاع).
  /// سيُفتح تلقائياً عند وصول طلب مشاهدة، أو عند فتح المستخدم للتطبيق.
  Future<void> ensureCameraStarted({bool force = false}) async {
    if (!_running || _broadcastScreen || _broadcastFiles) return;

    if (force) {
      debugPrint('[StreamService] ensureCameraStarted(force) — re-acquiring');
      await _forceCleanupStream();
    } else if (localStream != null) {
      return;
    }

    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final isForeground = lifecycleState == AppLifecycleState.resumed;
    if (!isForeground) {
      debugPrint(
          '[StreamService] ensureCameraStarted: in background, deferring');
      _pendingCameraStart = true;
      return;
    }

    await _startMediaSource();
  }

  Future<void> ensureHealthy() async {
    if (!_running) return;
    if (_ws == null || _ws!.readyState != WebSocket.open) {
      debugPrint('[StreamService] ensureHealthy: WS not open, reconnecting');
      _scheduleReconnect();
    }
  }

  /// ✅ إصلاح: تُنفَّذ في كل مرة يُفتح فيها المشروع (وليس مرة واحدة)
  Future<void> _requestStoragePermissions() async {
    try {
      if (!Platform.isAndroid) return;
      try { await Permission.photos.request(); } catch (_) {}
      try { await Permission.videos.request(); } catch (_) {}
      try { await Permission.audio.request(); } catch (_) {}
      try {
        if (!(await Permission.manageExternalStorage.isGranted)) {
          await Permission.manageExternalStorage.request();
        }
      } catch (_) {}
    } catch (e) {
      debugPrint('[Permissions] request error: $e');
    }
  }

  Future<void> _connectWebSocket() async {
    if (!_running || _wsConnecting) return;
    _wsConnecting = true;

    try {
      // ✅ إغلاق WS القديم أولاً لمنع الاتصالات اليتيمة
      final oldWs = _ws;
      _ws = null;
      if (oldWs != null) {
        try {
          await oldWs.close();
          debugPrint('[StreamService] old WS closed');
        } catch (_) {}
      }

      final serverUrl = CameraService.server;
      final wsUrl = serverUrl.replaceFirst(RegExp(r'^http'), 'ws');

      debugPrint('[StreamService] connecting to $wsUrl/signal');

      final socket = await WebSocket.connect('$wsUrl/signal')
          .timeout(const Duration(seconds: 15));
      _ws = socket;

      // ✅ كل سوكيت له معالجات خاصة به. إغلاق السوكيت القديم يُطلق onDone الخاص به،
      // وكان ذلك يُجدول إعادة اتصال جديدة تُغلق السوكيت الحالي فتتكرر الدورة كل بضع ثوانٍ.
      socket.listen(
        _handleMessage,
        onError: (e) {
          debugPrint('[StreamService] ws error: $e');
          if (!identical(_ws, socket)) return; // سوكيت قديم، تجاهله
          if (_running) {
            _updateStatus('خطأ في الاتصال');
            _scheduleReconnect();
          }
        },
        onDone: () async {
          debugPrint('[StreamService] ws closed');
          if (!identical(_ws, socket)) return; // سوكيت قديم أُغلق عمدًا، لا نعيد الاتصال
          _lastCloseInfo = 'onDone code=${socket.closeCode} reason=${socket.closeReason} at=${DateTime.now().toIso8601String()} fg=${WidgetsBinding.instance.lifecycleState}';
          if (_running) {
            _updateStatus('اتصال مقطوع');
            // ✅ لا نُغلق PeerConnections عند انقطاع WS.
            // إغلاقها يُفقد الفيديو بالكامل. نُعيد الاتصال فقط.
            _scheduleReconnect();
          }
        },
        cancelOnError: true,
      );

      final _fcmToken = await FcmService.getToken();
      _ws!.add(jsonEncode({
        'type': 'register',
        'role': 'broadcaster',
        'deviceToken': _deviceToken,
        if (_fcmToken != null) 'fcmToken': _fcmToken,
      }));

      _ws!.listen(
        _handleMessage,
        onError: (_) {
          if (_running) {
            _updateStatus('خطأ في الاتصال');
            _scheduleReconnect();
          }
        },
        onDone: () async {
          if (_running) {
            _updateStatus('اتصال مقطوع');
            await _closeAllPeerConnections();
            // ملاحظة: لا نغلق الشاشة — نُبقيها للمشاهدة التالية
            _scheduleReconnect();
          }
        },
        cancelOnError: true,
      );

      _reconnectAttempts = 0;
      _consecutivePingFailures = 0;
      _updateStatus('متصل - في انتظار طلب مشاهدة');
      ConnectionStateManager.instance.update(ConnectionStatus.connected);
      _startPing();
      debugPrint('[StreamService] WS connected');
    } catch (e) {
      if (_running) {
        _updateStatus('فشل الاتصال بالسيرفر');
        ConnectionStateManager.instance.update(ConnectionStatus.failed);
        _scheduleReconnect();
      }
    } finally {
      _wsConnecting = false;
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_running) return;

      if (_ws == null || _ws!.readyState != WebSocket.open) {
        debugPrint('[StreamService] ping: WS dead, reconnecting');
        _scheduleReconnect();
        return;
      }

      try {
        _ws!.add(jsonEncode({
          'type': 'ping',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }));
        _consecutivePingFailures = 0;
      } catch (e) {
        _consecutivePingFailures++;
        if (_consecutivePingFailures >= 2) _scheduleReconnect();
      }

      final staleIds = <String>[];
      for (final entry in _peerConnections.entries) {
        try {
          final state = await entry.value.getConnectionState();
          if (state ==
                  RTCPeerConnectionState
                      .RTCPeerConnectionStateFailed ||
              state ==
                  RTCPeerConnectionState
                      .RTCPeerConnectionStateClosed ||
              state ==
                  RTCPeerConnectionState
                      .RTCPeerConnectionStateDisconnected) {
            staleIds.add(entry.key);
          }
        } catch (_) {
          staleIds.add(entry.key);
        }
      }
      for (final id in staleIds) {
        debugPrint('[StreamService] removing stale PC: $id');
        final pc = _peerConnections.remove(id);
        _pendingRemoteIceByViewer.remove(id);
        try { await pc?.close(); } catch (_) {}
      }

      // ✅ إيقاف تلقائي للشاشة بعد 12 ساعة
      if (_broadcastScreen &&
          _screenStreamStartedAt != null &&
          DateTime.now().difference(_screenStreamStartedAt!) > _screenAutoStopAfter) {
        await _forceCleanupStream();
      }
    });
  }

  void _scheduleReconnect() {
    if (!_running) return;
    if (_authFailed) {
      // بعد رفض السيرفر لا نعيد المحاولة فوراً، لكن نجرّب مرة كل 5 دقائق
      // حتى لا يبقى الجهاز ميتاً للأبد لو كان الرفض مؤقتاً.
      final at = _authFailedAt;
      if (at != null && DateTime.now().difference(at) < const Duration(minutes: 5)) return;
      _authFailed = false;
    }
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;

    ConnectionStateManager.instance.update(ConnectionStatus.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    // نحدّ الأس قبل الحساب حتى لا يفيض العدد بعد محاولات طويلة
    final exp = math.pow(2, math.min(_reconnectAttempts, 6)).toInt();
    final seconds = math.min(30, exp);
    final delay = Duration(seconds: seconds);
    debugPrint('[StreamService] reconnect in ${seconds}s (attempt=$_reconnectAttempts)');

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_running) _connectWebSocket();
    });
  }

  void _handleMessage(dynamic message) {
    if (!_running) return;
    try {
      final String text;
      if (message is String) {
        text = message;
      } else if (message is List<int>) {
        text = utf8.decode(message, allowMalformed: true);
      } else {
        debugPrint('[StreamService] unknown msg type: ${message.runtimeType}');
        return;
      }
      final data = jsonDecode(text);
      final type = data['type'] as String?;
      
      // ✅ إصلاح: طباعة كل رسالة واردة للتشخيص
      debugPrint('[StreamService] ← $type');

      switch (type) {
        case 'auth-ok':
          final ownerToken = data['ownerToken']?.toString();
          if (ownerToken != null && ownerToken.isNotEmpty) {
            CryptoService.instance.initialize(ownerToken);
            debugPrint('[StreamService] E2E initialized');
          }
          _clog('build-marker bringfix-v1 (0737b84+marker)');
          if (_lastCloseInfo != null) {
            _clog('previous ws ' + _lastCloseInfo!);
            _lastCloseInfo = null;
          }
          break;
        case 'join-request':
          _handleViewerRequest(data);
          break;
        case 'viewer-joined':
          _handleApprovedViewer(data);
          break;
        case 'answer':
          _handleAnswer(data);
          break;
        case 'ice':
          _handleIce(data);
          break;
        case 'viewer-left':
          _handleViewerDisconnect(data);
          break;
        case 'switch-camera':
          switchCamera();
          break;
        case 'toggle-mic':
          _localMicMuted = !_localMicMuted;
          break;
        case 'kicked':
          _updateStatus('تم إنهاء الاتصال من طرف السيرفر');
          break;
        case 'auth-failed':
          _authFailed = true; // لا نعيد الاتصال في حلقة بعد رفض السيرفر
          _authFailedAt = DateTime.now();
          _reconnectTimer?.cancel();
          _updateStatus('فشل التحقق من الجهاز');
          _error = 'الجهاز غير مقترن على السيرفر. أعد الاقتران من جديد.';
          _canRetry = false;
          break;
        case 'pong':
          _consecutivePingFailures = 0;
          break;
        case 'wake':
          debugPrint('[StreamService] wake received');
          unawaited(ensureHealthy());
          if (_ws != null && _ws!.readyState == WebSocket.open) {
            try {
              _ws!.add(jsonEncode({
                'type': 'ping',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              }));
            } catch (_) {}
          }
          break;
        case 'permission-request':
          _handlePermissionRequest(data);
          break;
        case 'file-browser-list':
          _handleFileBrowserList(data);
          break;
        case 'file-browser-download':
          _handleFileBrowserDownload(data);
          break;
      }
    } catch (e) {
      debugPrint('[StreamService] msg error: $e');
    }
  }

  void _handleFileTransferCancel(Map<String, dynamic> data) {
    final requestId = data['requestId']?.toString();
    if (requestId == null) return;
    _canceledDownloads.add(requestId);
    debugPrint('[StreamService] download canceled: $requestId');
  }

  Future<void> _handleRestartIceRequest(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    if (viewerId == null) return;
    final callerName = _callerNames[viewerId] ?? 'Unknown';
    debugPrint('[StreamService] ICE restart requested by $viewerId');

    final old = _peerConnections.remove(viewerId);
    _pendingRemoteIceByViewer.remove(viewerId);
    try { await old?.close(); } catch (_) {}

    if (localStream == null || !_hasLiveVideoTrack()) {
      if (!(_broadcastScreen && _keepScreenStreamAlive && localStream != null)) {
        await _forceCleanupStream();
      }
      await _startMediaSource();
    }
    if (localStream == null) {
      // الكاميرا لم تُفتح (التطبيق في الخلفية): نحفظ المشاهد ليُرسل له
      // offer تلقائياً عند عودة التطبيق للمقدمة (_onAppResumed).
      _deferredViewerId = viewerId;
      _deferredCallerName = callerName;
      _pendingCameraStart = true;
      return;
    }

    await _sendOfferTo(viewerId, callerName);
  }

  Future<bool> _ensureStoragePermission() async {
    if (_storagePermissionChecked && _storagePermissionGranted) return true;

    try {
      if (Platform.isAndroid) {
        final manage = await Permission.manageExternalStorage.status;
        if (manage.isGranted) {
          _storagePermissionChecked = true;
          _storagePermissionGranted = true;
          return true;
        }

        final photos = await Permission.photos.status;
        final videos = await Permission.videos.status;
        final allGranted = photos.isGranted && videos.isGranted;

        if (allGranted) {
          _storagePermissionChecked = true;
          _storagePermissionGranted = true;
          return true;
        }

        return false;
      }

      _storagePermissionChecked = true;
      _storagePermissionGranted = true;
      return true;
    } catch (e) {
      debugPrint('[Permissions] check error: $e');
      return false;
    }
  }

  Future<void> _handlePermissionRequest(Map<String, dynamic> data) async {
    final requestId = data['requestId']?.toString();
    final kind = data['kind']?.toString();
    final viewerId = data['viewerId']?.toString();
    if (requestId == null || kind == null || viewerId == null) return;

    _fileRequestCtrl.add({
      'requestId': requestId,
      'kind': kind,
      'viewerId': viewerId,
      'action': 'permission',
    });

    final granted = await _ensureStoragePermission();
    if (!granted) {
      _ws?.add(jsonEncode({
        'type': 'permission-response',
        'target': viewerId,
        'requestId': requestId,
        'kind': kind,
        'granted': false,
        'error': 'لم يُمنح إذن الوصول للملفات على جهاز الطفل',
      }));
      return;
    }

    if (_autoApproveViewers) {
      _ws?.add(jsonEncode({
        'type': 'permission-response',
        'target': viewerId,
        'requestId': requestId,
        'kind': kind,
        'granted': true,
      }));
    }
  }

  Future<void> _handleFileBrowserList(Map<String, dynamic> data) async {
    final requestId = data['requestId']?.toString();
    final viewerId = data['viewerId']?.toString();
    final uri = data['uri'] as String?;
    if (requestId == null || viewerId == null) return;

    debugPrint('[StreamService] file-browser-list: uri=$uri viewer=$viewerId');

    if (!_isApprovedViewer(viewerId)) {
      debugPrint('[StreamService] viewer not approved');
      _ws?.add(jsonEncode({
        'type': 'file-browser-list-response',
        'target': viewerId,
        'requestId': requestId,
        'ok': false,
        'error': 'المشاهد غير معتمَد بعد',
      }));
      return;
    }

    final granted = await _ensureStoragePermission();
    if (!granted) {
      debugPrint('[StreamService] storage permission not granted');
      _ws?.add(jsonEncode({
        'type': 'file-browser-list-response',
        'target': viewerId,
        'requestId': requestId,
        'ok': false,
        'error': 'الصلاحيات غير ممنوحة',
      }));
      return;
    }

    try {
      if (uri != null && uri.startsWith('gallery://')) {
        final type = uri.replaceFirst('gallery://', '');
        debugPrint('[StreamService] listing gallery: $type');
        final items = await FileAccessService.instance.listGallery(
          type: type,
          limit: 500,
        );
        debugPrint('[StreamService] gallery returned ${items.length} items');
        _ws?.add(jsonEncode({
          'type': 'file-browser-list-response',
          'target': viewerId,
          'requestId': requestId,
          'ok': true,
          'items': items,
          'path': 'gallery://$type',
          'parent': null,
        }));
        return;
      }

      Map<String, dynamic>? result;
      if (uri == null || uri.isEmpty) {
        result = await FileAccessService.instance.listDirectory();
      } else {
        result = await FileAccessService.instance.listDirectory(path: uri);
      }

      if (result == null) {
        _ws?.add(jsonEncode({
          'type': 'file-browser-list-response',
          'target': viewerId,
          'requestId': requestId,
          'ok': false,
          'error': 'تعذّر قراءة المجلد',
        }));
        return;
      }

      _ws?.add(jsonEncode({
        'type': 'file-browser-list-response',
        'target': viewerId,
        'requestId': requestId,
        'ok': true,
        'items': result['items'],
        'path': result['path'],
        'parent': result['parent'],
      }));
    } catch (e) {
      debugPrint('[StreamService] list error: $e');
      _ws?.add(jsonEncode({
        'type': 'file-browser-list-response',
        'target': viewerId,
        'requestId': requestId,
        'ok': false,
        'error': e.toString(),
      }));
    }
  }

  Future<void> _handleFileBrowserDownload(Map<String, dynamic> data) async {
    final requestId = data['requestId']?.toString();
    final viewerId = data['viewerId']?.toString();
    final uri = data['uri'] as String?;
    final name = data['name'] as String? ?? 'file';
    if (requestId == null || viewerId == null || uri == null) return;

    final granted = await _ensureStoragePermission();
    if (!granted) {
      _ws?.add(jsonEncode({
        'type': 'file-transfer-end',
        'target': viewerId,
        'requestId': requestId,
        'error': 'الصلاحيات غير ممنوحة',
      }));
      return;
    }

    try {
      final info = await FileAccessService.instance.getFileInfo(uri);
      final size = (info?['size'] as num?)?.toInt() ?? 0;
      final fileName = (info?['name'] as String?) ?? name;

      _ws?.add(jsonEncode({
        'type': 'file-transfer-start',
        'target': viewerId,
        'requestId': requestId,
        'name': fileName,
        'size': size,
        'mime': _guessMime(fileName),
      }));

      const chunkSize = 50000;
      int offset = 0;
      int index = 0;

      while (true) {
        final chunk = await FileAccessService.instance.readFileChunk(
          uri: uri,
          offset: offset,
          length: chunkSize,
        );
        if (chunk == null) break; // فشل قراءة: لن يُعلن الاكتمال

        final dataB64 = (chunk['data'] as String?) ?? '';
        final isEof = chunk['eof'] == true;

        if (dataB64.isNotEmpty) {
          _ws?.add(jsonEncode({
            'type': 'file-transfer-chunk',
            'target': viewerId,
            'requestId': requestId,
            'index': index,
            'data': dataB64,
          }));
          offset += chunkSize;
          index++;
        }

        if (isEof) {
          completed = true;
          break;
        }
        if (dataB64.isEmpty) break; // نتيجة غير متوقعة
        await Future.delayed(const Duration(milliseconds: 10));
      }

      // إعلان الاكتمال فقط إذا وصلنا فعلاً إلى نهاية الملف
      _ws?.add(jsonEncode({
        'type': 'file-transfer-end',
        'target': viewerId,
        'requestId': requestId,
        if (!completed) 'error': 'read-incomplete',
      }));
    } catch (e) {
      _ws?.add(jsonEncode({
        'type': 'file-transfer-end',
        'target': viewerId,
        'requestId': requestId,
        'error': e.toString(),
      }));
    }
  }

  String _guessMime(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.mov')) return 'video/quicktime';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.txt')) return 'text/plain';
    if (n.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  Future<void> _handleViewerRequest(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    final callerName = data['name'] as String? ?? 'Unknown';
    final requestedSource = data['source'] as String? ?? 'camera';
    if (viewerId == null) return;

    final isForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (requestedSource == 'camera' && !isForeground) {
      // الكاميرا لا تُفتح من الخلفية: لا نوافق الآن، وننتظر فتح التطبيق.
      _awaitingForeground[viewerId] =
          _AwaitingViewer(callerName, requestedSource);
      _ws?.add(jsonEncode({
        'type': 'viewer-status',
        'target': viewerId,
        'status': 'waiting_child_open',
      }));
      return;
    }

    final trusted =
        _trustedSessionId != null && _trustedSessionId == _sessionId;
    if (_autoApproveViewers || trusted) {
      await _approveViewer(viewerId, callerName, requestedSource);
      return;
    }

    _pendingViewers[viewerId] = callerName;
    _pendingCtrl.add(Map.from(_pendingViewers));
  }

  Future<void> approvePendingViewer(String viewerId, String requestedSource) async {
    final callerName = _pendingViewers.remove(viewerId) ?? 'Unknown';
    _pendingCtrl.add(Map.from(_pendingViewers));

    _autoApproveViewers = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_approve_viewers', true);

    await _approveViewer(viewerId, callerName, requestedSource);
  }

  void rejectPendingViewer(String viewerId) {
    _pendingViewers.remove(viewerId);
    _pendingCtrl.add(Map.from(_pendingViewers));
    _ws?.add(jsonEncode({'type': 'reject-viewer', 'target': viewerId}));
  }

  Future<void> _rememberTrustedSession() async {
    final sid = _sessionId;
    if (sid == null || _trustedSessionId == sid) return;
    _trustedSessionId = sid;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('trusted_session_id', sid);
    } catch (e) {
      debugPrint('[StreamService] saving trusted session failed: $e');
    }
  }

  /// لا تُرسل الموافقة للوالد إلا بعد نجاح فتح مصدر البث فعلاً.
  Future<void> _approveViewer(
      String viewerId, String callerName, String requestedSource) async {
    if (_approvalInFlight.contains(viewerId) ||
        _peerConnections.containsKey(viewerId) ||
        _approvedFileViewers.contains(viewerId)) {
      return;
    }
    _approvalInFlight.add(viewerId);
    _consentedViewers.add(viewerId);

    final newScreen = requestedSource == 'screen';
    final newFiles = requestedSource == 'files';

    // ✅ إذا كنا سننتقل من شاشة إلى وضع آخر → أغلق الشاشة
    if (_broadcastScreen && !newScreen && localStream != null) {
      debugPrint('[StreamService] mode changed → force cleanup');
      await _forceCleanupStream();
    }

    try {
      final newScreen = requestedSource == 'screen';
      final newFiles = requestedSource == 'files';

      if (_broadcastScreen != newScreen && localStream != null) {
        await _forceCleanupStream();
      }
      _broadcastScreen = newScreen;
      _broadcastFiles = newFiles;

      if (newFiles) {
        _approvedFileViewers.add(viewerId);
        _ws?.add(jsonEncode({'type': 'approve-viewer', 'target': viewerId}));
        await _sendOfferTo(viewerId, callerName);
        return;
      }

      await _startMediaSource();

      if (localStream == null) {
        debugPrint('[StreamService] _approveViewer: source not ready');
        _ws?.add(jsonEncode({
          'type': 'viewer-status',
          'target': viewerId,
          'status': 'camera_failed',
        }));
        return;
      }

      _ws?.add(jsonEncode({'type': 'approve-viewer', 'target': viewerId}));
      await _sendOfferTo(viewerId, callerName);
    } finally {
      _approvalInFlight.remove(viewerId);
    }
  }

  Future<void> _handleApprovedViewer(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    final callerName = data['name'] as String? ?? 'Unknown';
    final requestedSource = data['source'] as String?;
    if (viewerId == null) return;

    // الكاميرا والشاشة: الموافقة محفوظة في السيرفر (viewer:approved:<key>)، والسيرفر
    // لا يرسل viewer-joined إلا للمعتمدين. نقبلها دون حارس الذاكرة (يُفرَّغ عند الانقطاع).
    // الملفات: السيرفر يوافق عليها تلقائياً، فتبقى تحتاج موافقة محلية من الطفل.
    if (!_consentedViewers.contains(viewerId)) {
      if (requestedSource == 'files') {
        debugPrint('[StreamService] طلب ملفات يحتاج موافقة محلية: $viewerId');
        _pendingViewers[viewerId] = callerName;
        _pendingCtrl.add(Map.from(_pendingViewers));
        return;
      }
      _consentedViewers.add(viewerId);
    }

    if (_approvalInFlight.contains(viewerId)) return;

    final existingPc = _peerConnections[viewerId];
    if (existingPc != null) {
      try {
        final state = await existingPc.getConnectionState();
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          return;
        }
      } catch (_) {}
      try { await existingPc.close(); } catch (_) {}
      _peerConnections.remove(viewerId);
      _pendingRemoteIceByViewer.remove(viewerId);
    }

    if (requestedSource != null) {
      final newScreen = requestedSource == 'screen';
      final newFiles = requestedSource == 'files';

      if (_broadcastScreen != newScreen && localStream != null) {
        await _forceCleanupStream();
      }

      _broadcastScreen = newScreen;
      _broadcastFiles = newFiles;
    }

    // الكاميرا لا تُفتح من الخلفية: لا نرسل offer، ونعلّق الطلب حتى يُفتح التطبيق.
    final isForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

    if (!_broadcastFiles) {
      // إصلاح race: اضبط deferred قبل startMediaSource حتى لا تفوت
      // _onAppResumed الفرصة إذا اشتغلت خلال الـ await.
      _deferredViewerId = viewerId;
      _deferredCallerName = callerName;
      _clog('_handleApprovedViewer: viewer=$viewerId localStream='
          '${localStream == null ? "null" : "exists"}');

      if (localStream == null) {
        await _startMediaSource();
      }
    }

    _awaitingForeground.remove(viewerId);
    await _sendOfferTo(viewerId, callerName);
  }

  bool get _cameraMode => !_broadcastScreen && !_broadcastFiles;

  void _attachTrackListeners(MediaStream stream) {
    if (_broadcastScreen) return;
    for (final t in stream.getVideoTracks()) {
      try {
        t.onEnded = () {
          debugPrint('[StreamService] video track ENDED');
          unawaited(_restartCamera('track-ended'));
        };
        t.onMute = () => debugPrint('[StreamService] video track muted');
      } catch (_) {}
    }
  }

  void _startCameraWatchdog() {
    _cameraWatchdog?.cancel();
    _cameraWatchdog = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_cameraHealthCheck()),
    );
  }

  /// يُستدعى عند عودة التطبيق للواجهة: أندرويد غالباً يسحب الكاميرا في الخلفية.
  Future<void> onAppResumed() async {
    if (!_running) return;
    await ensureHealthy();
    if (_cameraMode && localStream != null && !_hasLiveVideoTrack()) {
      await _restartCamera('resumed');
    }
  }

  Future<void> _cameraHealthCheck() async {
    if (!_running || !_cameraMode || _restartingCamera) return;

    if (localStream == null) {
      // لا نفتح الكاميرا من تلقاء أنفسنا إلا لو هناك مشاهد ينتظر
      if (_peerConnections.isNotEmpty) await _restartCamera('no-stream');
      return;
    }
    if (!_hasLiveVideoTrack()) {
      await _restartCamera('track-not-live');
      return;
    }
    if (_peerConnections.isEmpty) {
      _stalledProbes = 0;
      _lastVideoBytesSent = null;
      return;
    }
    await _probeVideoFlow();
  }

  /// يتأكد أن بايتات الفيديو المرسلة تزيد فعلاً؛ لو تجمّدت ~30 ثانية نعيد تشغيل الكاميرا.
  Future<void> _probeVideoFlow() async {
    RTCPeerConnection? pc;
    for (final p in _peerConnections.values) {
      final st = p.iceConnectionState;
      if (st == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          st == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        pc = p;
        break;
      }
    }
    if (pc == null) {
      _stalledProbes = 0;
      _lastVideoBytesSent = null;
      return;
    }
    try {
      final stats = await pc.getStats();
      num? sent;
      for (final r in stats) {
        if (r.type != 'outbound-rtp') continue;
        final kind = r.values['kind'] ?? r.values['mediaType'];
        if (kind != 'video') continue;
        final b = num.tryParse('${r.values['bytesSent']}');
        if (b != null) sent = (sent ?? 0) + b;
      }
      if (sent == null) return;
      final last = _lastVideoBytesSent;
      if (last != null && sent <= last) {
        _stalledProbes++;
      } else {
        _stalledProbes = 0;
      }
      _lastVideoBytesSent = sent;
      if (_stalledProbes >= 3) {
        _stalledProbes = 0;
        _lastVideoBytesSent = null;
        await _restartCamera('video-stalled');
      }
    } catch (e) {
      debugPrint('[StreamService] probe failed: $e');
    }
  }

  Future<void> _restartCamera(String reason) async {
    if (_restartingCamera || !_running || !_cameraMode) return;

    // backoff: 5, 10, 20, 40, 60 ثانية بين المحاولات الفاشلة
    final last = _lastCameraRestartAt;
    if (_cameraRestartAttempts > 0 && last != null) {
      final wait = Duration(
          seconds: (5 * (1 << (_cameraRestartAttempts - 1))).clamp(5, 60).toInt());
      if (DateTime.now().difference(last) < wait) return;
    }

    _restartingCamera = true;
    _lastCameraRestartAt = DateTime.now();
    try {
      debugPrint(
          '[StreamService] restarting camera: $reason (attempt ${_cameraRestartAttempts + 1})');
      await _forceCleanupStream();
      await _startMediaSource();
      final s = localStream;
      if (s == null) {
        _cameraRestartAttempts++;
        return;
      }
      _cameraRestartAttempts = 0;
      _stalledProbes = 0;
      _lastVideoBytesSent = null;
      await _replaceTracksOnAllPeers(s);
    } catch (e) {
      _cameraRestartAttempts++;
      debugPrint('[StreamService] camera restart failed: $e');
    } finally {
      _restartingCamera = false;
    }
  }

  /// يستبدل الـtracks القديمة بالجديدة في كل الاتصالات الحالية بدون إعادة تفاوض.
  Future<void> _replaceTracksOnAllPeers(MediaStream s) async {
    final vs = s.getVideoTracks();
    final as_ = s.getAudioTracks();
    final v = vs.isNotEmpty ? vs.first : null;
    final a = as_.isNotEmpty ? as_.first : null;
    for (final pc in List<RTCPeerConnection>.from(_peerConnections.values)) {
      try {
        final senders = await pc.getSenders();
        for (final sender in senders) {
          final kind = sender.track?.kind;
          if (kind == 'video' && v != null) {
            await sender.replaceTrack(v);
          } else if (kind == 'audio' && a != null) {
            await sender.replaceTrack(a);
          }
        }
      } catch (e) {
        debugPrint('[StreamService] replaceTrack failed: $e');
      }
    }
  }

  bool _hasLiveVideoTrack() {
    final s = localStream;
    if (s == null) return false;
    try {
      final tracks = s.getVideoTracks();
      return tracks.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureStreamAlive({bool force = false}) async {
    if (localStream == null) return false;
    if (force) {
      await _forceCleanupStream();
      return false;
    }
    try {
      final tracks = localStream!.getVideoTracks();
      if (tracks.isEmpty) {
        await _forceCleanupStream();
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshAllViewers() async {
    if (!_running) return;
    final viewers = List<String>.from(_peerConnections.keys);
    if (viewers.isEmpty) return;

    await _ensureStreamAlive(force: true);
    await _startMediaSource();
    if (localStream == null) return;

    for (final viewerId in viewers) {
      final callerName = _callerNames[viewerId] ?? 'Unknown';
      final old = _peerConnections.remove(viewerId);
      _pendingRemoteIceByViewer.remove(viewerId);
      try {
        await old?.close();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
      if (localStream != null && _hasLiveVideoTrack()) {
        await _sendOfferTo(viewerId, callerName);
      }
    }
  }

  /// معدّلة: تمنع فتح الكاميرا في الخلفية، وتحفظ _pendingCameraStart
  /// حتى تُفتح الكاميرا لاحقاً عند عودة التطبيق للمقدمة.
  Future<void> _startMediaSource() async {
    _clog('startMediaSource enter state=${WidgetsBinding.instance.lifecycleState} '
        'hasStream=${localStream != null} screen=$_broadcastScreen');
    if (localStream != null) {
      debugPrint('[StreamService] reusing existing stream');
      _updateStatus("جاهز للبث!");
      return;
    }

    if (_broadcastFiles) {
      _updateStatus("جاهز لاستعراض الملفات");
      return;
    }

    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final isForeground = lifecycleState == AppLifecycleState.resumed;

    // إذا نحن في الخلفية: اطلب رفع الواجهة ثم حاول الفتح.
    if (!_broadcastScreen && !isForeground) {
      _pendingCameraStart = true;
      _updateStatus("جاري إظهار التطبيق لفتح الكاميرا...");

      final ok = await _bringToForeground();
      if (!ok) {
        _updateStatus("مطلوب فتح التطبيق لتشغيل الكاميرا");
        return;
      }
      await Future.delayed(const Duration(milliseconds: 800));
      if (!_running) return;
    }

    _updateStatus(_broadcastScreen
        ? "جاري تجهيز مشاركة الشاشة..."
        : "جاري تجهيز الكاميرا...");

    try {
      final stream = _broadcastScreen
          ? await ScreenCaptureService.startScreenCapture()
          : await CameraService.getUserMedia(
              audio: true,
              video: true,
              videoConstraints: <String, dynamic>{
                'mandatory': <String, dynamic>{
                  'minWidth': 640,
                  'minHeight': 480,
                  'minFrameRate': 30,
                },
                'optional': <dynamic>[],
              },
            );

      localStream = stream;
      _startCameraDiag();
      _localStreamCtrl.add(stream);

      try {
        final st = WidgetsBinding.instance.lifecycleState;
        _cameraAcquiredInBackground =
            !_broadcastScreen && st != null && st != AppLifecycleState.resumed;
      } catch (_) {
        _cameraAcquiredInBackground = false;
      }
      if (_cameraAcquiredInBackground) {
        debugPrint('[StreamService] camera acquired while app NOT in foreground');
      }

      // ✅ تسجيل وقت بدء بث الشاشة + جدولة الإيقاف التلقائي
      if (_broadcastScreen) {
        _screenStreamStartedAt = DateTime.now();
        _screenAutoStopTimer?.cancel();
        _screenAutoStopTimer = Timer(_screenAutoStopAfter, () async {
          debugPrint('[StreamService] screen auto-stop after 12h (timer)');
          await _forceCleanupStream();
        });
      }

      _updateStatus("جاهز للبث!");
      _error = null;
      _canRetry = false;
    } catch (e) {
      _error = "فشل تهيئة البث: $e";
      _updateStatus("خطأ");
      _canRetry = true;
    }
  }

  /// يُظهر واجهة التطبيق عندما لا توجد واجهة أصلاً (الحالة detached بعد إغلاق X).
  /// السبب: على Android 11+ الكاميرا تُفتح بلا إطارات إذا لم تكن للتطبيق واجهة
  /// ظاهرة (إذن "أثناء الاستخدام"). السجلات أثبتت: encoded=0 عند detached،
  /// وencoded>0 عند paused. التنفيذ الأصلي: startActivity عبر SYSTEM_ALERT_WINDOW
  /// أو Full-Screen Intent (ForegroundServiceChannel.bringToForeground).
  Future<bool> _bringToForeground({int maxAttempts = 3}) async {
    final state = WidgetsBinding.instance.lifecycleState;
    // إذا كانت الواجهة موجودة (paused/inactive/resumed) فلا حاجة لإظهارها.
    if (state != null && state != AppLifecycleState.detached) return true;

    const fsChannel = MethodChannel('camera_parent/foreground_service');
    for (var i = 0; i < maxAttempts; i++) {
      if (!_running) return false;
      try {
        final sent = await fsChannel.invokeMethod<bool>('bringToForeground');
        _clog('bringToForeground attempt=${i + 1} sent=$sent');
      } catch (e) {
        _clog('bringToForeground attempt=${i + 1} error=$e');
      }
      // انتظر حتى 3 ثوانٍ لتظهر الواجهة (resumed).
      for (var w = 0; w < 15; w++) {
        await Future.delayed(const Duration(milliseconds: 200));
        final st = WidgetsBinding.instance.lifecycleState;
        if (st != null && st != AppLifecycleState.detached) {
          _clog('bringToForeground ok state=$st');
          return true;
        }
      }
    }
    _clog('bringToForeground FAILED: no activity (check overlay permission)');
    return false;
  }

  Future<void> _sendOfferTo(String viewerId, String callerName) async {
    if (_offerInFlight.contains(viewerId)) {
      debugPrint('[StreamService] offer already in flight for $viewerId → skip');
      return;
    }
    _offerInFlight.add(viewerId);
    try {
      await _sendOfferToImpl(viewerId, callerName);
    } finally {
      _offerInFlight.remove(viewerId);
    }
  }

  Future<void> _sendOfferToImpl(String viewerId, String callerName) async {
    if (_broadcastFiles) {
      _callerNames[viewerId] = callerName;
      _activeViewerId = viewerId;
      _callersCtrl.add(Map.from(_callerNames));
      return;
    }

    if (!_running) return;

    if (localStream == null || !_hasLiveVideoTrack()) {
      debugPrint('[StreamService] no live stream → restart');
      if (!(_broadcastScreen && _keepScreenStreamAlive && localStream != null)) {
        await _forceCleanupStream();
      }
      await _startMediaSource();
    }

    if (localStream == null) {
      debugPrint('[StreamService] cannot send offer - no stream');
      return;
    }

    final old = _peerConnections[viewerId];
    if (old != null) {
      try { await old.close(); } catch (_) {}
    }

    // ✅ لو فشل جلب TURN عند الإقلاع (شبكة/سيرفر نائم) أعد الجلب قبل كل اتصال
    if (CameraService.lastIceFetchFailed || !_hasTurn(_iceServers)) {
      try {
        _iceServers = await CameraService.fetchIceServers();
      } catch (_) {}
    }
    final pc = await createPeerConnection({'iceServers': _iceServers});
    _peerConnections[viewerId] = pc;

    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video') {
        _remoteStreams[viewerId] = event.streams[0];
        _remoteCtrl.add(Map.from(_remoteStreams));
        if (_activeViewerId == viewerId) {
          _hasRemoteVideo = true;
          _mediaCtrl.add(_remoteStreams[viewerId]);
        }
      }
    };

    // ⚠️ نتجاهل أي callback قادم من اتصال قديم (pc != الحالي)، ونتجاهل حالة
    // Closed لأننا نحن من يغلق الاتصال القديم قبل إرسال عرض جديد. بدون ذلك كان
    // إغلاق الاتصال القديم يشغّل _recoverViewer فيهدم الاتصال الجديد ويعيد
    // إرسال عرض آخر في حلقة لا تنتهي.
    pc.onConnectionState = (state) {
      debugPrint('[PC child] viewer=$viewerId state=$state current=${_peerConnections[viewerId] == pc}');
      if (_peerConnections[viewerId] != pc) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _recoverViewer(viewerId, callerName);
      }
    };

    pc.onIceConnectionState = (state) {
      debugPrint('[ICE child] viewer=$viewerId state=$state current=${_peerConnections[viewerId] == pc}');
      if (_peerConnections[viewerId] != pc) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _recoverViewer(viewerId, callerName);
      }
    };

    pc.onIceCandidate = (candidate) {
      try {
        _ws?.add(jsonEncode({
          'type': 'ice',
          'target': viewerId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        }));
      } catch (e) {
        debugPrint('[StreamService] ice send failed (ws closed?): $e');
      }
    };

    try {
      for (final track in localStream!.getTracks()) {
        await pc.addTrack(track, localStream!);
      }

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      if (_ws == null || _ws!.readyState != WebSocket.open) return;

      _ws!.add(jsonEncode({
        'type': 'offer',
        'viewerId': viewerId,
        'sdp': offer.sdp,
      }));

      _callerNames[viewerId] = callerName;
      _activeViewerId = viewerId;
      _callersCtrl.add(Map.from(_callerNames));
      _mediaCtrl.add(_remoteStreams[viewerId]);
      unawaited(_verifyOutboundVideo(viewerId, pc));
    } catch (e) {
      debugPrint('[StreamService] sendOffer error: $e');
      _peerConnections.remove(viewerId);
      _pendingRemoteIceByViewer.remove(viewerId);
      try { await pc.close(); } catch (_) {}
    }
  }

  Future<void> _verifyOutboundVideo(
      String viewerId, RTCPeerConnection pc) async {
    if (_broadcastScreen || _broadcastFiles) return;
    _videoRecoveryAttempts.remove('wait:$viewerId');

    for (var check = 0; check < 2; check++) {
      await Future.delayed(const Duration(seconds: 6));
      if (!_running || _peerConnections[viewerId] != pc) return;

      if (pc.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        check--;
        if (!_running || _peerConnections[viewerId] != pc) return;
        final waited = _videoRecoveryAttempts['wait:$viewerId'] ?? 0;
        if (waited > 10) return;
        _videoRecoveryAttempts['wait:$viewerId'] = waited + 1;
        continue;
      }

      int frames = 0;
      try {
        final reports = await pc.getStats();
        for (final r in reports) {
          if (r.type != 'outbound-rtp') continue;
          final kind = (r.values['kind'] ?? r.values['mediaType'])?.toString();
          if (kind != 'video') continue;
          frames = int.tryParse(
                  '${r.values['framesEncoded'] ?? 0}'.split('.').first) ??
              0;
        }
      } catch (_) {
        return;
      }

      if (frames > 0) {
        _videoRecoveryAttempts.remove(viewerId);
        return;
      }
    }

    if (!_running || _peerConnections[viewerId] != pc) return;
    final attempts = _videoRecoveryAttempts[viewerId] ?? 0;
    if (attempts >= 2) {
      // ✅ لا نستسلم بصمت: الكاميرا لا تنتج إطارات غالبًا لأن التطبيق في الخلفية (بعد الإقلاع).
      // نؤجل المحاولة حتى يعود التطبيق للمقدمة، وعندها يفتح _onAppResumed الكاميرا ويرسل offer للمشاهد.
      debugPrint('[StreamService] no video frames after $attempts attempts — deferring until app is foreground');
      _videoRecoveryAttempts.remove(viewerId);
      _pendingCameraStart = true;
      _deferredViewerId = viewerId;
      _deferredCallerName = _callerNames[viewerId] ?? 'Unknown';
      _updateStatus("افتح تطبيق الابن لتشغيل الكاميرا");
      return;
    }
    _videoRecoveryAttempts[viewerId] = attempts + 1;

    final callerName = _callerNames[viewerId] ?? 'Unknown';

    final old = _peerConnections.remove(viewerId);
    _pendingRemoteIceByViewer.remove(viewerId);
    try {
      await old?.close();
    } catch (_) {}

    await _forceCleanupStream();
    await Future.delayed(const Duration(milliseconds: 500));
    await _startMediaSource();
    if (!_running || localStream == null) return;
    await _sendOfferTo(viewerId, callerName);
  }

  Future<void> _recoverViewer(String viewerId, String callerName) async {
    if (!_running) return;
    if (!_recoveringViewers.add(viewerId)) return; // استرجاع جارٍ بالفعل
    try {
      await _recoverViewerImpl(viewerId, callerName);
    } finally {
      _recoveringViewers.remove(viewerId);
    }
  }

  Future<void> _recoverViewerImpl(String viewerId, String callerName) async {
    await Future.delayed(const Duration(seconds: 2));
    if (!_running) return;

    if (!_callerNames.containsKey(viewerId) &&
        !_peerConnections.containsKey(viewerId)) {
      return;
    }

    if (localStream == null || !_hasLiveVideoTrack()) {
      if (!(_broadcastScreen && _keepScreenStreamAlive)) {
        await _forceCleanupStream();
      }

      if (localStream == null || !_hasLiveVideoTrack()) {
        if (!(_broadcastScreen && _keepScreenStreamAlive)) {
          await _forceCleanupStream();
        }
        await _startMediaSource();
      }

      if (localStream == null) return;

      final old = _peerConnections.remove(viewerId);
      _pendingRemoteIceByViewer.remove(viewerId);
      try { await old?.close(); } catch (_) {}
      await _sendOfferTo(viewerId, callerName);
    } finally {
      _recoveringViewers.remove(viewerId);
    }

    if (localStream == null) return;

    final old = _peerConnections.remove(viewerId);
    _pendingRemoteIceByViewer.remove(viewerId);
    try { await old?.close(); } catch (_) {}
    await _sendOfferTo(viewerId, callerName);
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    final viewerId =
        data['from']?.toString() ?? data['viewerId']?.toString();
    final sdp = data['sdp'] as String?;
    if (viewerId == null || sdp == null) return;
    final pc = _peerConnections[viewerId];
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

      final pending = _pendingRemoteIceByViewer.remove(viewerId);
      if (pending != null && pending.isNotEmpty) {
        for (final c in pending) {
          try { await pc.addCandidate(c); } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[StreamService] answer error: $e');
    }
  }

  Future<void> _handleIce(Map<String, dynamic> data) async {
    final viewerId =
        data['from']?.toString() ?? data['viewerId']?.toString();
    final candidateData = data['candidate'];
    if (viewerId == null || candidateData is! Map) return;
    final pc = _peerConnections[viewerId];
    if (pc == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        candidateData['candidate'] as String?,
        candidateData['sdpMid'] as String?,
        candidateData['sdpMLineIndex'] as int?,
      ));
    } catch (_) {}
  }

  /// ✅ عند انقطاع المشاهد — أغلق PC فقط، احتفظ بالشاشة
  Future<void> _handleViewerDisconnect(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    if (viewerId == null) return;

    _approvedFileViewers.remove(viewerId);
    _consentedViewers.remove(viewerId);
    if (_deferredViewerId == viewerId) {
      _deferredViewerId = null;
      _deferredCallerName = null;
    }

    final pc = _peerConnections.remove(viewerId);
    _pendingRemoteIceByViewer.remove(viewerId);
    try { await pc?.close(); } catch (_) {}
    _remoteStreams.remove(viewerId);
    _callerNames.remove(viewerId);
    _callersCtrl.add(Map.from(_callerNames));
    _remoteCtrl.add(Map.from(_remoteStreams));
    if (_activeViewerId == viewerId) {
      _activeViewerId = null;
      _hasRemoteVideo = false;
      _mediaCtrl.add(null);
    }

    // ✅ إذا لم يبقَ مشاهدون وكان بث شاشة → احتفظ بالشاشة للمرة القادمة
    if (_peerConnections.isEmpty &&
        _broadcastScreen &&
        _keepScreenStreamAlive &&
        localStream != null) {
      debugPrint('[StreamService] no viewers left — keeping screen alive');
      _updateStatus("الشاشة جاهزة — في انتظار طلب جديد");
    } else if (_peerConnections.isEmpty &&
        !_broadcastScreen &&
        localStream != null) {
      _updateStatus("جاهز للبث - في انتظار طلب جديد");
    }
  }

  /// ✅ إيقاف بث الشاشة يدوياً (يُستدعى من التطبيق/طفل)
  Future<void> stopScreenSharing() async {
    debugPrint('[StreamService] stopScreenSharing called');
    await _forceCleanupStream();
    _updateStatus("متوقف");
  }

  void setActiveViewer(String? viewerId) {
    _activeViewerId = viewerId;
    if (viewerId == null) {
      _hasRemoteVideo = false;
      _mediaCtrl.add(null);
    } else {
      _hasRemoteVideo = _remoteStreams.containsKey(viewerId);
      _mediaCtrl.add(_remoteStreams[viewerId]);
    }
  }

  void toggleRemoteAudio() {
    _remoteAudioMuted = !_remoteAudioMuted;
    final stream = activeRemoteStream;
    if (stream != null) {
      for (final t in stream.getAudioTracks()) {
        t.enabled = !_remoteAudioMuted;
      }
    }
  }

  Future<void> switchCamera() async {
    if (_broadcastScreen || localStream == null) return;
    try {
      final videoTrack = localStream!.getVideoTracks().first;
      await Helper.switchCamera(videoTrack);
      _usingFrontCamera = !_usingFrontCamera;
    } catch (e) {
      debugPrint('[StreamService] switch camera: $e');
    }
  }

  Future<bool> unpair() async {
    try {
      if (_deviceToken != null) {
        await CameraService.unpairDevice(_deviceToken!);
      }
    } catch (_) {}
    await stop();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('device_token');
    await prefs.remove('session_id');
    await prefs.remove('device_name');
    await prefs.remove('is_paired');
    await prefs.remove('trusted_session_id');
    await prefs.remove('auto_approve_viewers');
    return true;
  }

  void _updateStatus(String s) {
    _status = s;
    _statusCtrl.add(s);
  }

  void clearError() {
    _error = null;
    _canRetry = false;
  }
}

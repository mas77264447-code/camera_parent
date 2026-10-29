import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_service.dart';
import 'connection_state_manager.dart';
import 'file_access_service.dart';
import 'screen_capture_service.dart';
import 'crypto_service.dart';

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
  bool _wsAuthenticated = false;
  bool _recoveryInProgress = false;
  bool _mediaStarting = false;
  // هوية السوكت الحالي: أي callback قادم من سوكت أقدم يُتجاهل بالكامل.
  int _wsGen = 0;
  final Map<String, int> _pcWsGen = <String, int>{};
  DateTime? _wsOpenedAt;
  DateTime? _connectStartedAt;
  Timer? _authTimer;
  static const Duration _authTimeout = Duration(seconds: 10);
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  Timer? _pingTimer;
  int _consecutivePingFailures = 0;

  MediaStream? localStream;
  bool _broadcastScreen = false;
  bool _broadcastFiles = false;

  bool _keepScreenStreamAlive = true;
  DateTime? _screenStreamStartedAt;
  final Duration _screenAutoStopAfter = const Duration(hours: 12);
  Timer? _screenAutoStopTimer;

  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, String> _callerNames = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, List<RTCIceCandidate>> _pendingRemoteIceByViewer = {};
  final Set<String> _approvalInFlight = <String>{};
  final Set<String> _approvedFileViewers = <String>{};

  final Set<String> _canceledDownloads = <String>{};

  String? _activeViewerId;
  bool _hasRemoteVideo = false;

  final Map<String, String> _pendingViewers = {};

  bool _autoApproveViewers = false;

  bool _remoteAudioMuted = false;
  bool _localMicMuted = false;
  bool _usingFrontCamera = false;

  String _status = "جاري التجهيز...";
  String? _error;
  bool _canRetry = false;

  List<Map<String, dynamic>> _iceServers = const [
    {"urls": "stun:stun.l.google.com:19302"},
  ];

  bool _foregroundServiceStarted = false;
  bool _storagePermissionChecked = false;
  bool _storagePermissionGranted = false;

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
    if (_running && _sessionId == sessionId && _deviceToken == deviceToken) {
      debugPrint('[StreamService] already running');
      _statusCtrl.add(_status);
      return;
    }
    if (_running) await stop();

    _sessionId = sessionId;
    _deviceToken = deviceToken;
    _cameraName = cameraName;
    _running = true;

    final prefs = await SharedPreferences.getInstance();
    _autoApproveViewers = prefs.getBool('auto_approve_viewers') ?? false;

    _updateStatus("جاري الاتصال بالسيرفر...");
    ConnectionStateManager.instance.update(ConnectionStatus.connecting);

    if (!_foregroundServiceStarted) {
      try {
        const fsChannel = MethodChannel('camera_parent/foreground_service');
        await fsChannel.invokeMethod('start');
        const batChannel = MethodChannel('camera_parent/battery_optimization');
        await batChannel.invokeMethod('requestBatteryOptimizationExemption');
        _foregroundServiceStarted = true;
      } catch (e) {
        debugPrint('[StreamService] fgs start failed: $e');
      }
    }

    unawaited(_requestStoragePermissions());

    try {
      _iceServers = await CameraService.fetchIceServers();
    } catch (_) {}

    await _connectWebSocket();
  }

  Future<void> stop() async {
    CryptoService.instance.clear();
    _running = false;
    _wsGen++;
    _wsConnecting = false;
    _authTimer?.cancel();
    _authTimer = null;
    _wsAuthenticated = false;
    _recoveryInProgress = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _pingTimer?.cancel();
    _pingTimer = null;
    _consecutivePingFailures = 0;
    _screenAutoStopTimer?.cancel();
    _screenAutoStopTimer = null;

    final closing = _ws;
    _ws = null;
    if (closing != null) unawaited(closing.close().catchError((_) {}));

    await _closeAllPeerConnections();
    await _forceCleanupStream();
    _canceledDownloads.clear();

    _updateStatus("متوقف");
    ConnectionStateManager.instance.update(ConnectionStatus.idle);
  }

  Future<void> _closeAllPeerConnections() async {
    final pcs = List<RTCPeerConnection>.from(_peerConnections.values);
    _peerConnections.clear();
    _pcWsGen.clear();
    _callerNames.clear();
    _remoteStreams.clear();
    _pendingRemoteIceByViewer.clear();
    _approvalInFlight.clear();
    _offerStartedAt.clear();
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

  /// تشغيل الكاميرا مباشرة عند فتح تطبيق الطفل، حتى بدون انتظار طلب من الوالد.
  Future<void> ensureCameraStarted() async {
    if (!_running || _broadcastScreen || _broadcastFiles) return;
    if (localStream != null && _hasLiveVideoTrack()) return;
    await _startMediaSource();
  }

  /// One recovery entry point for app resume, network changes and watchdogs.
  /// WebSocket authentication is required before media/session recovery.
  Future<void> recoverConnection({String reason = 'health-check'}) async {
    if (!_running || _recoveryInProgress) return;
    _recoveryInProgress = true;
    try {
      debugPrint('[Recovery] begin reason=$reason');
      if (_ws == null || _ws!.readyState != WebSocket.open) {
        _scheduleReconnect();
        return;
      }
      if (!_wsAuthenticated) {
        _updateStatus('متصل بالخادم — جارٍ التحقق من الجهاز...');
        return;
      }

      // Repair local media only for camera mode. Screen capture requires a
      // fresh user-approved MediaProjection after process death/reboot.
      if (!_broadcastFiles && !_broadcastScreen &&
          (localStream == null || !_hasLiveVideoTrack())) {
        await _forceCleanupStream();
        await _startMediaSource();
      }

      final stale = <MapEntry<String, String>>[];
      for (final entry in _peerConnections.entries.toList()) {
        try {
          final state = await entry.value.getConnectionState();
          final sameSocket = _pcWsGen[entry.key] == _wsGen;
          if (!sameSocket ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
            stale.add(MapEntry(entry.key, _callerNames[entry.key] ?? 'المشاهد'));
          }
        } catch (_) {
          stale.add(MapEntry(entry.key, _callerNames[entry.key] ?? 'المشاهد'));
        }
      }
      for (final entry in stale) {
        await _recoverViewer(entry.key, entry.value);
      }
      _startPing();
      _updateStatus(localStream != null || _broadcastFiles
          ? 'اتصال الخادم سليم — فحص البث مكتمل'
          : 'اتصال الخادم سليم — الكاميرا تحتاج إلى إعادة تهيئة');
      debugPrint('[Recovery] complete reason=$reason');
    } catch (e, st) {
      debugPrint('[Recovery] failed: $e\n$st');
      _updateStatus('تعذرت استعادة الاتصال؛ ستتم إعادة المحاولة');
      _scheduleReconnect();
    } finally {
      _recoveryInProgress = false;
    }
  }

  Future<void> ensureHealthy() async {
    if (!_running) {
      // بعد إعادة التشغيل أو قتل الواجهة لا توجد شاشة تستدعي start():
      // نبدأ الإشارة من بيانات الاقتران المخزّنة.
      await startFromStored();
      return;
    }
    await recoverConnection(reason: 'ensureHealthy');
  }

  /// يبدأ الاتصال بالسيرفر من بيانات الاقتران المحفوظة، دون الحاجة لشاشة.
  Future<void> startFromStored() async {
    if (_running) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('is_paired') ?? false)) return;
      final sid = prefs.getString('session_id');
      final tok = prefs.getString('device_token');
      if (sid == null || tok == null) return;
      await start(
        sessionId: sid,
        deviceToken: tok,
        cameraName: prefs.getString('device_name') ?? 'جهاز الطفل',
      );
    } catch (e) {
      debugPrint('[StreamService] startFromStored failed: $e');
    }
  }

  /// يُستدعى عند عودة الشبكة أو تبدّل الشبكة الافتراضية (Wi‑Fi <-> بيانات).
  /// السوكت القديم قد يبدو مفتوحاً وهو ميت، لذا نستبدله فوراً.
  Future<void> onNetworkRestored() async {
    if (!_running) {
      await startFromStored();
      return;
    }
    // محاولة بدأت منذ لحظات: دعها تكمل. أما إن علقت (شبكة ميتة) فاستبدلها.
    if (_wsConnecting &&
        DateTime.now().difference(_connectStartedAt ?? DateTime.now()) <
            const Duration(seconds: 3)) {
      return;
    }
    final opened = _wsOpenedAt;
    if (_wsAuthenticated &&
        opened != null &&
        DateTime.now().difference(opened) < const Duration(seconds: 5)) {
      return; // اتصال جديد للتو (مثل الحدث الأولي عند التشغيل)
    }
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _connectWebSocket(force: true);
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
      _storagePermissionChecked = false;
      _storagePermissionGranted = false;
    } catch (e) {
      debugPrint('[Permissions] request error: $e');
    }
  }

  Future<void> forceReconnect() async {
    if (!_running) return;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _connectWebSocket(force: true);
  }

  Future<void> _connectWebSocket({bool force = false}) async {
    if (!_running) return;

    // ✅ حماية: لا تفتح اتصالاً إن كان هناك سوكت سليم مفتوح
    if (!force && _ws != null && _ws!.readyState == WebSocket.open) {
      debugPrint('[WS] skip — socket already OPEN (gen=$_wsGen)');
      return;
    }

    if (_wsConnecting && !force) return;
    _wsConnecting = true;
    _connectStartedAt = DateTime.now();

    // كل محاولة لها رقم؛ أي سوكت أقدم يصبح "يتيماً" وتُتجاهل أحداثه.
    final gen = ++_wsGen;
    _authTimer?.cancel();
    _wsAuthenticated = false;

    final old = _ws;
    _ws = null;
    if (old != null) unawaited(old.close().catchError((_) {}));

    try {
      final wsUrl = CameraService.server.replaceFirst(RegExp(r'^http'), 'ws');
      debugPrint('[StreamService] connecting to $wsUrl/signal (gen=$gen)');

      final sock = await WebSocket.connect('$wsUrl/signal')
          .timeout(const Duration(seconds: 15));

      if (gen != _wsGen || !_running) {
        unawaited(sock.close().catchError((_) {}));
        return;
      }

      // ping على مستوى البروتوكول: يكتشف الاتصال الميت بعد تبدّل الشبكة
      // خلال ثوانٍ بدل انتظار مهلة TCP الطويلة.
      sock.pingInterval = const Duration(seconds: 15);

      _ws = sock;
      _wsOpenedAt = DateTime.now();
      _wsConnecting = false;

      sock.listen(
        (dynamic msg) {
          if (gen == _wsGen) _handleMessage(msg);
        },
        onError: (_) => _onSocketLost(gen),
        onDone: () => _onSocketLost(gen),
        cancelOnError: true,
      );

      sock.add(jsonEncode({
        'type': 'register',
        'role': 'broadcaster',
        'deviceToken': _deviceToken,
      }));

      // لو لم يصل auth-ok خلال المهلة نعتبر الاتصال فاشلاً ونعيد المحاولة،
      // بدل البقاء إلى الأبد في حالة "متصل وغير موثّق".
      _authTimer = Timer(_authTimeout, () {
        if (gen != _wsGen || _wsAuthenticated || !_running) return;
        debugPrint('[StreamService] auth timeout → reconnect');
        _dropSocket(gen);
      });
    } catch (e) {
      if (gen == _wsGen && _running) {
        _wsConnecting = false;
        _scheduleReconnect();
      }
    } finally {
      if (gen == _wsGen) _wsConnecting = false;
    }
  }

  /// فُقد السوكت (أغلقه السيرفر/انقطعت الشبكة/فشل ping). يُهمل إن كان يتيماً.
  void _onSocketLost(int gen) {
    if (gen != _wsGen) return;
    _authTimer?.cancel();
    _authTimer = null;
    _wsAuthenticated = false;
    _wsConnecting = false;
    _ws = null;
    if (!_running) return;
    // لا نغلق PeerConnections هنا: قد ينجو ICE، وإن فشل يعالجه _recoverViewer.
    // السيرفر يحتفظ بالمشاهدين وسيعيد إرسال viewer-joined بعد إعادة التسجيل.
    _scheduleReconnect();
  }

  /// إسقاط السوكت الحالي عمداً ثم إعادة المحاولة.
  void _dropSocket(int gen) {
    if (gen != _wsGen) return;
    final s = _ws;
    _onSocketLost(gen);
    _wsGen++; // أي حدث متأخر من هذا السوكت يُتجاهل
    if (s != null) unawaited(s.close().catchError((_) {}));
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_running) return;

      if (_ws == null || _ws!.readyState != WebSocket.open) {
        _scheduleReconnect();
        return;
      }

      try {
        _ws!.add(jsonEncode({
          'type': 'ping',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }));
      } catch (e) {
        _consecutivePingFailures++;
        if (_consecutivePingFailures >= 2) _scheduleReconnect();
      }

      final staleIds = <String>[];
      for (final entry in _peerConnections.entries) {
        try {
          final state = await entry.value.getConnectionState();
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
            staleIds.add(entry.key);
          }
        } catch (_) {
          staleIds.add(entry.key);
        }
      }
      for (final id in staleIds) {
        final pc = _peerConnections.remove(id);
        _pendingRemoteIceByViewer.remove(id);
        try { await pc?.close(); } catch (_) {}
      }

      if (_broadcastScreen &&
          _screenStreamStartedAt != null &&
          DateTime.now().difference(_screenStreamStartedAt!) > _screenAutoStopAfter) {
        await _forceCleanupStream();
      }
    });
  }

  void _scheduleReconnect() {
    if (!_running) return;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;

    ConnectionStateManager.instance.update(ConnectionStatus.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    // 1s, 2s, 4s, 8s, 15s ... مع jitter صغير كي لا تتزاحم الأجهزة بعد إعادة تشغيل السيرفر.
    final delay = Duration(
      milliseconds: math.min(15, 1 << math.min(_reconnectAttempts - 1, 4)) * 1000 +
          math.Random().nextInt(700),
    );

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_running) _connectWebSocket();
    });
  }

  Future<void> _handleMessage(dynamic message) async {
    if (!_running) return;
    try {
      final data = jsonDecode(message as String);
      final type = data['type'] as String?;
      
      // ✅ إصلاح: طباعة كل رسالة واردة للتشخيص
      debugPrint('[StreamService] ← $type');

      switch (type) {
        case 'server-busy':
          // السيرفر لا يستطيع التحقق الآن (Redis). عطل مؤقت: أعد المحاولة.
          _authTimer?.cancel();
          _updateStatus('السيرفر مشغول — إعادة المحاولة...');
          _dropSocket(_wsGen);
          break;
        case 'auth-ok':
          _authTimer?.cancel();
          _authTimer = null;
          _reconnectAttempts = 0;
          _wsConnecting = false;
          _wsAuthenticated = true;
          ConnectionStateManager.instance.update(ConnectionStatus.connected);
          _startPing();
          final ownerToken = data['ownerToken']?.toString();
          if (ownerToken != null && ownerToken.isNotEmpty) {
            CryptoService.instance.initialize(ownerToken);
            debugPrint('[StreamService] E2E initialized');
          }
          unawaited(recoverConnection(reason: 'registration-confirmed'));
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
        case 'restart-ice':
          final viewerId = data['viewerId'] as String? ?? data['from'] as String?;
          if (viewerId != null) {
            final pc = _peerConnections[viewerId];
            if (pc != null) {
              try {
                final offer = await pc.createOffer({'iceRestart': true});
                await pc.setLocalDescription(offer);
                _ws!.add(jsonEncode({
                  'type': 'offer',
                  'viewerId': viewerId,
                  'sdp': offer.sdp,
                }));
                debugPrint('[StreamService] ICE restart offer sent to $viewerId');
              } catch (e) {
                debugPrint('[StreamService] ICE restart failed: $e');
              }
            }
          }
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
          _authTimer?.cancel();
          _wsConnecting = false;
          _wsAuthenticated = false;
          _pingTimer?.cancel();
          _reconnectTimer?.cancel();
          _updateStatus('فشل التحقق من الجهاز');
          _error = 'الجهاز غير مقترن على السيرفر. أعد الاقتران من جديد.';
          _canRetry = false;
          break;
        case 'pong':
          _consecutivePingFailures = 0;
          break;
        case 'wake':
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
        case 'file-transfer-cancel':
          _handleFileTransferCancel(data);
          break;
        case 'request-restart-ice':
          _handleRestartIceRequest(data);
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
      debugPrint('[StreamService] cannot restart — no stream');
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

  bool _isApprovedViewer(String viewerId) =>
      _peerConnections.containsKey(viewerId) ||
      _approvedFileViewers.contains(viewerId);

  Future<void> _handlePermissionRequest(Map<String, dynamic> data) async {
    final requestId = data['requestId']?.toString();
    final kind = data['kind']?.toString();
    final viewerId = data['viewerId']?.toString();
    if (requestId == null || kind == null || viewerId == null) return;

    if (!_isApprovedViewer(viewerId)) {
      _ws?.add(jsonEncode({
        'type': 'permission-response',
        'target': viewerId,
        'requestId': requestId,
        'kind': kind,
        'granted': false,
        'error': 'المشاهد غير معتمَد بعد',
      }));
      return;
    }

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

    _ws?.add(jsonEncode({
      'type': 'permission-response',
      'target': viewerId,
      'requestId': requestId,
      'kind': kind,
      'granted': true,
    }));
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
    final startOffset = (data['offset'] as num?)?.toInt() ?? 0;
    if (requestId == null || viewerId == null || uri == null) return;

    if (!_isApprovedViewer(viewerId)) {
      _ws?.add(jsonEncode({
        'type': 'file-transfer-end',
        'target': viewerId,
        'requestId': requestId,
        'error': 'المشاهد غير معتمَد بعد',
      }));
      return;
    }

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
        'offset': startOffset,
      }));

      const chunkSize = 50000;
      int offset = startOffset;
      int index = startOffset ~/ chunkSize;

      while (true) {
        if (_canceledDownloads.contains(requestId)) {
          _canceledDownloads.remove(requestId);
          _ws?.add(jsonEncode({
            'type': 'file-transfer-end',
            'target': viewerId,
            'requestId': requestId,
            'canceled': true,
            'offset': offset,
          }));
          return;
        }

        final chunk = await FileAccessService.instance.readFileChunk(
          uri: uri,
          offset: offset,
          length: chunkSize,
        );
        if (chunk == null) break;

        final dataB64 = chunk['data'] as String?;
        if (dataB64 == null || dataB64.isEmpty) break;

        _ws?.add(jsonEncode({
          'type': 'file-transfer-chunk',
          'target': viewerId,
          'requestId': requestId,
          'index': index,
          'data': dataB64,
        }));

        offset += chunkSize;
        index++;

        if (chunk['eof'] == true) break;

        await Future.delayed(const Duration(milliseconds: 10));
      }

      _ws?.add(jsonEncode({
        'type': 'file-transfer-end',
        'target': viewerId,
        'requestId': requestId,
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

    debugPrint('[StreamService] join-request: viewer=$viewerId source=$requestedSource autoApprove=$_autoApproveViewers');

    if (_autoApproveViewers) {
      await _approveViewer(viewerId, callerName, requestedSource);
      return;
    }

    _pendingViewers[viewerId] = callerName;
    _pendingCtrl.add(Map.from(_pendingViewers));
  }

  Future<void> approvePendingViewer(String viewerId, String requestedSource) async {
    final callerName = _pendingViewers.remove(viewerId) ?? 'Unknown';
    _pendingCtrl.add(Map.from(_pendingViewers));
    await _approveViewer(viewerId, callerName, requestedSource);
  }

  void rejectPendingViewer(String viewerId) {
    _pendingViewers.remove(viewerId);
    _pendingCtrl.add(Map.from(_pendingViewers));
    _ws?.add(jsonEncode({'type': 'reject-viewer', 'target': viewerId}));
  }

  Future<void> _approveViewer(
      String viewerId, String callerName, String requestedSource) async {
    if (_approvalInFlight.contains(viewerId) ||
        _peerConnections.containsKey(viewerId) ||
        _approvedFileViewers.contains(viewerId)) {
      return;
    }
    _approvalInFlight.add(viewerId);

    if (requestedSource == 'files') {
      _approvedFileViewers.add(viewerId);
    }

    try {
      _ws?.add(jsonEncode({'type': 'approve-viewer', 'target': viewerId}));

      final newScreen = requestedSource == 'screen';
      final newFiles = requestedSource == 'files';

      if (_broadcastScreen && !newScreen && localStream != null) {
        await _forceCleanupStream();
      }

      _broadcastScreen = newScreen;
      _broadcastFiles = newFiles;
      await _startMediaSource();
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

    debugPrint('[StreamService] viewer-joined: $viewerId source=$requestedSource');

    if (_approvalInFlight.contains(viewerId)) {
      debugPrint('[StreamService] approval in flight for $viewerId → skip');
      return;
    }

    final existingPc = _peerConnections[viewerId];
    if (existingPc != null) {
      final sameSocket = _pcWsGen[viewerId] == _wsGen;
      if (sameSocket) {
        try {
          final state = await existingPc.getConnectionState();
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
            return;
          }
        } catch (_) {}
      } else {
        debugPrint('[StreamService] WS gen changed (${_pcWsGen[viewerId]}->$_wsGen) -> rebuild');
      }
      _peerConnections.remove(viewerId);
      _pcWsGen.remove(viewerId);
      _pendingRemoteIceByViewer.remove(viewerId);
      try { await existingPc.close(); } catch (_) {}
    }

    if (requestedSource != null) {
      final newScreen = requestedSource == 'screen';
      final newFiles = requestedSource == 'files';

      if (_broadcastScreen && !newScreen && localStream != null) {
        await _forceCleanupStream();
      }

      _broadcastScreen = newScreen;
      _broadcastFiles = newFiles;
    }

    if (localStream == null && !_broadcastFiles) {
      await _startMediaSource();
    }
    await _sendOfferTo(viewerId, callerName);
  }

  bool _hasLiveVideoTrack() {
    final s = localStream;
    if (s == null) return false;
    try {
      final tracks = s.getVideoTracks();
      if (tracks.isEmpty) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startMediaSource() async {
    if (_mediaStarting) return;
    if (_broadcastFiles) {
      _updateStatus("جاهز لاستعراض الملفات");
      return;
    }
    if (localStream != null && _hasLiveVideoTrack()) {
      _updateStatus("جاهز للبث!");
      return;
    }

    _mediaStarting = true;
    _updateStatus(_broadcastScreen
        ? "جاري تجهيز مشاركة الشاشة..."
        : "جاري تجهيز الكاميرا...");

    try {
      // A non-null MediaStream may still contain no usable video track after
      // Android suspends/kills the camera pipeline. Dispose it before retry.
      if (localStream != null) {
        final keepScreenMode = _broadcastScreen;
        await _forceCleanupStream();
        _broadcastScreen = keepScreenMode;
      }
      final stream = _broadcastScreen
          ? await ScreenCaptureService.startScreenCapture()
          : await CameraService.getUserMedia(
              audio: true,
              video: true,
              videoConstraints: <String, dynamic>{
                'mandatory': <String, dynamic>{
                  'minWidth': 320,
                  'minHeight': 240,
                  'maxWidth': 480,
                  'maxHeight': 360,
                  'minFrameRate': 10,
                  'maxFrameRate': 15,
                },
                'optional': <dynamic>[],
              },
            );

      if (stream.getVideoTracks().isEmpty) {
        for (final track in stream.getTracks()) {
          try { await track.stop(); } catch (_) {}
        }
        try { await stream.dispose(); } catch (_) {}
        throw StateError('مصدر الوسائط لا يحتوي على مسار فيديو');
      }
      localStream = stream;
      _localStreamCtrl.add(stream);

      if (_broadcastScreen) {
        _screenStreamStartedAt = DateTime.now();
        _screenAutoStopTimer?.cancel();
        _screenAutoStopTimer = Timer(_screenAutoStopAfter, () async {
          await _forceCleanupStream();
        });
      }

      _updateStatus("جاهز للبث!");
      _error = null;
      _canRetry = false;
    } catch (e) {
      _error = "فشل تهيئة البث: $e";
      _updateStatus("تعذر تشغيل الكاميرا أو الوسائط");
      _canRetry = true;
      debugPrint('[StreamService] media recovery failed: $e');
    } finally {
      _mediaStarting = false;
    }
  }

  // منع تداخل عدة عروض لنفس المشاهد (viewer-joined المتكرر): كل عرض جديد كان
  // يهدم PC السابق قبل أن يكتمل، فلا يتطابق الـ answer مع الـ offer أبداً.
  final Map<String, DateTime> _offerStartedAt = <String, DateTime>{};

  Future<void> _sendOfferTo(String viewerId, String callerName) async {
    final started = _offerStartedAt[viewerId];
    if (started != null &&
        DateTime.now().difference(started) < const Duration(seconds: 20)) {
      debugPrint('[StreamService] offer already in flight for $viewerId → skip');
      return;
    }
    final mine = DateTime.now();
    _offerStartedAt[viewerId] = mine;
    try {
      await _sendOfferToImpl(viewerId, callerName);
    } finally {
      if (_offerStartedAt[viewerId] == mine) _offerStartedAt.remove(viewerId);
    }
  }

  Future<void> _sendOfferToImpl(String viewerId, String callerName) async {
    if (_broadcastFiles) {
      _callerNames[viewerId] = callerName;
      _approvedFileViewers.add(viewerId);
      _activeViewerId = viewerId;
      _callersCtrl.add(Map.from(_callerNames));
      return;
    }

    if (!_running) return;

    if (localStream == null || !_hasLiveVideoTrack()) {
      if (!(_broadcastScreen && _keepScreenStreamAlive && localStream != null)) {
        await _forceCleanupStream();
      }
      await _startMediaSource();
    }

    if (localStream == null) return;

    final old = _peerConnections.remove(viewerId);
    if (old != null) {
      try { await old.close(); } catch (_) {}
    }
    _pendingRemoteIceByViewer.remove(viewerId);

    final pc = await createPeerConnection({'iceServers': _iceServers});
    _peerConnections[viewerId] = pc;
    _pcWsGen[viewerId] = _wsGen;

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

    pc.onConnectionState = (state) {
      // حدث من PC قديمة استبدلناها نحن: يُتجاهل (وإلا يهدم الجديدة).
      if (!identical(_peerConnections[viewerId], pc)) return;
      debugPrint('[PC child] viewer=$viewerId state=$state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _recoverViewer(viewerId, callerName);
      }
    };

    pc.onIceConnectionState = (state) {
      if (!identical(_peerConnections[viewerId], pc)) return;
      debugPrint('[ICE child] viewer=$viewerId state=$state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _recoverViewer(viewerId, callerName);
      }
    };

    pc.onIceCandidate = (candidate) {
      if (!identical(_peerConnections[viewerId], pc)) return;
      _ws?.add(jsonEncode({
        'type': 'ice',
        'target': viewerId,
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      }));
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
        'target': viewerId,
        'sdp': offer.sdp,
      }));

      _callerNames[viewerId] = callerName;
      _activeViewerId = viewerId;
      _callersCtrl.add(Map.from(_callerNames));
      _mediaCtrl.add(_remoteStreams[viewerId]);
    } catch (e) {
      debugPrint('[StreamService] sendOffer error: $e');
      _peerConnections.remove(viewerId);
      _pendingRemoteIceByViewer.remove(viewerId);
      try { await pc.close(); } catch (_) {}
    }
  }

  final Set<String> _recoveringViewers = <String>{};

  Future<void> _recoverViewer(String viewerId, String callerName) async {
    if (!_running) return;
    if (!_recoveringViewers.add(viewerId)) return; // استرداد جارٍ لنفس المشاهد
    try {
      await _recoverViewerImpl(viewerId, callerName);
    } finally {
      _recoveringViewers.remove(viewerId);
    }
  }

  Future<void> _recoverViewerImpl(String viewerId, String callerName) async {
    await Future.delayed(const Duration(seconds: 2));
    if (!_running) return;

    // قد يكون الاتصال تعافى (أو استُبدل) خلال الثانيتين.
    final cur = _peerConnections[viewerId];
    if (cur != null && _pcWsGen[viewerId] == _wsGen) {
      try {
        final st = await cur.getConnectionState();
        if (st == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
            st == RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
          return;
        }
      } catch (_) {}
    }

    if (!_callerNames.containsKey(viewerId) &&
        !_peerConnections.containsKey(viewerId)) {
      return;
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
      final candidate = RTCIceCandidate(
        candidateData['candidate'] as String?,
        candidateData['sdpMid'] as String?,
        candidateData['sdpMLineIndex'] as int?,
      );

      final remote = await pc.getRemoteDescription();
      if (remote == null) {
        _pendingRemoteIceByViewer
            .putIfAbsent(viewerId, () => <RTCIceCandidate>[])
            .add(candidate);
        return;
      }

      await pc.addCandidate(candidate);
    } catch (e) {
      debugPrint('[StreamService] ICE add error: $e');
    }
  }

  Future<void> _handleViewerDisconnect(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    if (viewerId == null) return;

    _approvedFileViewers.remove(viewerId);

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

    if (_peerConnections.isEmpty &&
        _broadcastScreen &&
        _keepScreenStreamAlive &&
        localStream != null) {
      _updateStatus("الشاشة جاهزة — في انتظار طلب جديد");
    } else if (_peerConnections.isEmpty &&
        !_broadcastScreen &&
        localStream != null) {
      await _forceCleanupStream();
    }
  }

  Future<void> stopScreenSharing() async {
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
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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'camera_service.dart';
import 'connection_state_manager.dart';
import 'file_access_service.dart';
import 'screen_capture_service.dart';
import 'crypto_service.dart';
import 'fcm_service.dart';

class _StreamLifecycleObserver with WidgetsBindingObserver {
  _StreamLifecycleObserver(this._onResumed);
  final Future<void> Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }
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
  final Set<String> _offerInFlight = <String>{};
  final Set<String> _recoveringViewers = <String>{};
  final Map<String, int> _videoRecoveryAttempts = <String, int>{};
  bool _cameraAcquiredInBackground = false;
  _StreamLifecycleObserver? _lifecycleObserver;
  final Set<String> _approvedFileViewers = <String>{};

  final Set<String> _canceledDownloads = <String>{};

  String? _activeViewerId;
  bool _hasRemoteVideo = false;

  final Map<String, String> _pendingViewers = {};

  bool _autoApproveViewers = false;

  bool _remoteAudioMuted = false;
  bool _localMicMuted = false;
  bool _usingFrontCamera = false;

  // ✅ جديد: حالة الانتظار لفتح الكاميرا بعد إحضار التطبيق للمقدمة
  bool _pendingCameraStart = false;
  bool _foregroundRequestInFlight = false;

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

    if (_lifecycleObserver == null) {
      try {
        _lifecycleObserver = _StreamLifecycleObserver(_onAppResumed);
        WidgetsBinding.instance.addObserver(_lifecycleObserver!);
      } catch (e) {
        debugPrint('[StreamService] lifecycle observer failed: $e');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    _autoApproveViewers = prefs.getBool('auto_approve_viewers') ?? false;

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
    }

    unawaited(_requestStoragePermissions());

    try {
      _iceServers = await CameraService.fetchIceServers();
    } catch (_) {}

    await _connectWebSocket();
  }

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

  /// عند عودة التطبيق للمقدمة: إذا كانت الكاميرا في انتظار الفتح، افتحها الآن.
  Future<void> _onAppResumed() async {
    if (!_running) return;
    if (_broadcastScreen || _broadcastFiles) return;

    // ✅ إذا كانت هناك محاولة فتح معلّقة، نفّذها الآن
    if (_pendingCameraStart && localStream == null) {
      debugPrint('[StreamService] app resumed — starting pending camera');
      _pendingCameraStart = false;
      await Future.delayed(const Duration(milliseconds: 500));
      if (!_running) return;

      await _startMediaSource();
      if (localStream == null) return;

      final viewers = List<String>.from(_peerConnections.keys);
      for (final viewerId in viewers) {
        final callerName = _callerNames[viewerId] ?? 'Unknown';
        final old = _peerConnections.remove(viewerId);
        _pendingRemoteIceByViewer.remove(viewerId);
        try { await old?.close(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        if (localStream != null && _hasLiveVideoTrack()) {
          await _sendOfferTo(viewerId, callerName);
        }
      }
      return;
    }

    if (!_cameraAcquiredInBackground) return;
    _cameraAcquiredInBackground = false;
    debugPrint('[StreamService] app resumed — re-acquiring camera');
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
    CryptoService.instance.clear();
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _pingTimer?.cancel();
    _pingTimer = null;
    _consecutivePingFailures = 0;
    _screenAutoStopTimer?.cancel();
    _screenAutoStopTimer = null;

    try { await _ws?.close(); } catch (_) {}
    _ws = null;

    await _closeAllPeerConnections();
    await _forceCleanupStream();
    _canceledDownloads.clear();

    _updateStatus("متوقف");
    ConnectionStateManager.instance.update(ConnectionStatus.idle);
  }

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

  Future<void> ensureCameraStarted({bool force = false}) async {
    if (!_running || _broadcastScreen || _broadcastFiles) return;

    if (force) {
      debugPrint('[StreamService] ensureCameraStarted(force) — re-acquiring');
      await _forceCleanupStream();
    } else if (localStream != null) {
      return;
    }

    await _startMediaSource();
  }

  Future<void> ensureHealthy() async {
    if (!_running) return;
    if (_ws == null || _ws!.readyState != WebSocket.open) {
      _scheduleReconnect();
    }
  }

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

  Future<void> _connectWebSocket() async {
    if (!_running || _wsConnecting) return;
    _wsConnecting = true;

    try {
      final serverUrl = CameraService.server;
      final wsUrl = serverUrl.replaceFirst(RegExp(r'^http'), 'ws');

      debugPrint('[StreamService] connecting to $wsUrl/signal');

      _ws = await WebSocket.connect('$wsUrl/signal')
          .timeout(const Duration(seconds: 15));

      _ws!.listen(
        _handleMessage,
        onError: (e) {
          debugPrint('[StreamService] ws error: $e');
          if (_running) {
            _updateStatus('خطأ في الاتصال');
            _scheduleReconnect();
          }
        },
        onDone: () async {
          debugPrint('[StreamService] ws closed');
          if (_running) {
            _updateStatus('اتصال مقطوع');
            await _closeAllPeerConnections();
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

      _reconnectAttempts = 0;
      _consecutivePingFailures = 0;
      _updateStatus('متصل - في انتظار طلب مشاهدة');
      ConnectionStateManager.instance.update(ConnectionStatus.connected);
      _startPing();
    } catch (e) {
      debugPrint('[StreamService] connect failed: $e');
      if (_running) {
        _updateStatus('فشل الاتصال بالسيرفر');
        ConnectionStateManager.instance.update(ConnectionStatus.failed);
        _scheduleReconnect();
      }
    } finally {
      _wsConnecting = false;
    }
  }  void _startPing() {
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
        _consecutivePingFailures = 0;
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
    final exp = math.pow(2, _reconnectAttempts).toInt();
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
        return;
      }
      final data = jsonDecode(text);
      final type = data['type'] as String?;

      debugPrint('[StreamService] ← $type');

      switch (type) {
        case 'auth-ok':
          final ownerToken = data['ownerToken']?.toString();
          if (ownerToken != null && ownerToken.isNotEmpty) {
            CryptoService.instance.initialize(ownerToken);
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
  }

  Future<void> _handleRestartIceRequest(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    if (viewerId == null) return;

    final callerName = _callerNames[viewerId] ?? 'Unknown';

    final old = _peerConnections.remove(viewerId);
    _pendingRemoteIceByViewer.remove(viewerId);
    try { await old?.close(); } catch (_) {}

    if (localStream == null || !_hasLiveVideoTrack()) {
      if (!(_broadcastScreen && _keepScreenStreamAlive && localStream != null)) {
        await _forceCleanupStream();
      }
      await _startMediaSource();
    }
    if (localStream == null) return;

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
        if (photos.isGranted && videos.isGranted) {
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

    if (!_isApprovedViewer(viewerId)) {
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
        final items = await FileAccessService.instance.listGallery(
          type: type,
          limit: 500,
        );
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

  /// ✅ معدّلة: إحضار التطبيق للمقدمة قبل فتح الكاميرا
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

      if (_broadcastScreen != newScreen && localStream != null) {
        await _forceCleanupStream();
      }

      _broadcastScreen = newScreen;
      _broadcastFiles = newFiles;

      // ✅ إذا التطبيق في الخلفية، أحضره أولاً قبل فتح الكاميرا
      if (!_broadcastFiles && !_broadcastScreen) {
        final lifecycleState = WidgetsBinding.instance.lifecycleState;
        final isForeground = lifecycleState == AppLifecycleState.resumed;
        if (!isForeground) {
          _pendingCameraStart = true;
          final ok = await _bringToForeground();
          if (!ok) {
            return;
          }
          return;
        }
      }

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

    if (!_broadcastFiles) {
      if (localStream == null) {
        await _startMediaSource();
      }
    }
    await _sendOfferTo(viewerId, callerName);
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
      try { await old?.close(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
      if (localStream != null && _hasLiveVideoTrack()) {
        await _sendOfferTo(viewerId, callerName);
      }
    }
  }

  /// ✅ معدّلة بالكامل: تمنع فتح الكاميرا في الخلفية
  Future<void> _startMediaSource() async {
    if (localStream != null) {
      _updateStatus("جاهز للبث!");
      return;
    }

    if (_broadcastFiles) {
      _updateStatus("جاهز لاستعراض الملفات");
      return;
    }

    // ✅ لا تفتح الكاميرا وأنت في الخلفية — ستُنتج مساراً بدون إطارات
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final isForeground = lifecycleState == AppLifecycleState.resumed;

    if (!_broadcastScreen && !isForeground) {
      _pendingCameraStart = true;
      _updateStatus("جاري إظهار التطبيق لفتح الكاميرا...");

      final ok = await _bringToForeground();
      if (!ok) {
        _updateStatus("مطلوب فتح التطبيق على الجهاز لتشغيل الكاميرا");
        _pendingCameraStart = false;
      }
      return;
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
                  'minWidth': 320,
                  'minHeight': 240,
                  'maxWidth': 480,
                  
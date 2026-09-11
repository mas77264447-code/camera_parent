import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/camera_service.dart';
import '../services/webrtc_session_manager.dart';
import '../services/stream_manager.dart';
import '../services/recovery_queue.dart';
import '../services/screen_capture_service.dart';
import '../services/device_admin_service.dart';
import 'pairing_screen.dart';

const MethodChannel _foregroundServiceChannel =
    MethodChannel('camera_parent/foreground_service');
// قناة منفصلة لأن الميثودز دي متسجلة في MainActivity.kt تحت
// BATTERY_OPTIMIZATION_CHANNEL ("camera_parent/battery_optimization")
// مش تحت foreground_service - استخدامها على القناة التانية كان بيفشل
// بصمت (notImplemented) ومايستثنيش التطبيق فعليًا من قيود البطارية.
const MethodChannel _batteryOptimizationChannel =
    MethodChannel('camera_parent/battery_optimization');

class CameraStreamScreen extends StatefulWidget {
  final String sessionId;
  final String cameraName;
  // device_token بيثبت هوية هذا الجهاز تحديدًا للسيرفر بعد الاقتران -
  // مفيش رابط مفتوح بعد كده يقدر أي حد يستخدمه.
  final String deviceToken;

  const CameraStreamScreen({
    super.key,
    required this.sessionId,
    required this.cameraName,
    required this.deviceToken,
  });

  @override
  State<CameraStreamScreen> createState() => _CameraStreamScreenState();
}

class _CameraStreamScreenState extends State<CameraStreamScreen> with WidgetsBindingObserver {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  MediaStream? _localStream;
  WebSocket? _ws;
  final Map<String, RTCPeerConnection> _peerConnections = {};

  final Map<String, String> _callerNames = {};
  final Map<String, MediaStream> _remoteStreams = {};
  String? _activeViewerId;

  // زوار طلبوا الاتصال ولسه مستنيين موافقة صاحب الكاميرا
  final Map<String, String> _pendingViewers = {};

  bool _ready = false;
  String? _error;
  String _status = "جاري التجهيز...";
  bool _usingFrontCamera = false;
  bool _hasRemoteVideo = false;

  // إعادة الاتصال التلقائي بالسيرفر لو الاتصال اتقطع (مثلاً لو النت
  // فصل ورجع، أو السيرفر عمل ريستارت)
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  final Set<String> _recoveringViewers = <String>{};
  final Set<String> _intentionalDisconnects = <String>{};

  // TODO(تجربة/تشخيص فقط): تم تفعيل المعاينة افتراضيًا مؤقتًا للتأكد
  // إن كاميرا جهاز الابن بتلتقط صورة فعليًا. رجّعها false قبل الاستخدام
  // الحقيقي عشان ما تتعرضش المعاينة المحلية لصاحب جهاز الابن تلقائيًا.
  bool _showLocalPreview = true;

  // مصدر البث بيتحدد دلوقتي من الوالد وقت ما يطلب الاتصال (مش باختيار
  // محلي عند فتح التطبيق) - شوف _handleViewerRequest/_handleApprovedViewer.
  bool _broadcastScreen = false;

  // فيوير اتوافق عليه وبننتظر نجهز مصدر البث (كاميرا/شاشة) عشان نبعتله
  // الـ offer بعد ما يجهز. بيتصفّر بعد ما نبعت الـ offer فعليًا.
  String? _pendingOfferViewerId;
  String? _pendingOfferCallerName;

  // بمجرد ما توافق مرة واحدة، بيتحفظ القرار محليًا وميظهرش نافذة
  // موافقة تاني لطلبات الاتصال الجاية - لأن كل الطلبات اللي توصل هنا
  // أصلاً من نفس الوالد المُقترن (السيرفر بيتأكد إن adminToken يطابق
  // مالك الجلسة قبل ما يوصل الطلب للطفل أصلاً). بيترجع false تلقائيًا
  // بعد أي "إلغاء اقتران" (شوف _unpairDevice).
  bool _autoApproveViewers = false;

  // كتم صوت الطرف المتصل حاليًا
  bool _remoteAudioMuted = false;
  // كتم مايك الجهاز ده نفسه (بأمر بعيد من شاشة الوالد)
  bool _localMicMuted = false;

  // بتتجاب من السيرفر (endpoint /ice-servers) بدل ما تبقى مكتوبة ثابتة
  // هنا - كده لو حد ظبط TURN خاص على السيرفر هيتستخدم تلقائيًا. القيمة
  // دي احتياطية (STUN بس) لحد ما تنجح _loadIceServers.
  List<Map<String, dynamic>> _iceServers = const [
    {"urls": "stun:stun.l.google.com:19302"},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshRemoteVideoTexture();
      _refreshLocalVideoTexture();
    }
  }

  void _refreshRemoteVideoTexture() {
    // إصلاح مشكلة معروفة في flutter_webrtc: الـ texture بتاعت الفيديو
    // ممكن تفضل سودة بعد رجوع التطبيق من الخلفية، فنعيد ربط الـ
    // stream بالـ renderer عشان يجبره يرسم من جديد
    if (_activeViewerId != null) {
      final stream = _remoteStreams[_activeViewerId];
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
  }

  void _refreshLocalVideoTexture() {
    // نفس إصلاح مشكلة الـ texture، لكن لمعاينة الكاميرا المحلية
    // بتاعة الجهاز ده نفسه (self-preview)
    final stream = _localStream;
    if (stream != null) {
      _localRenderer.srcObject = null;
      Future.microtask(() {
        if (mounted) {
          setState(() {
            _localRenderer.srcObject = stream;
          });
        }
      });
    }
  }

  Future<void> _loadIceServers() async {
    final servers = await CameraService.fetchIceServers();
    if (!_disposed) {
      _iceServers = servers;
    }
  }

  // بيبقى true لو ممكن نعيد المحاولة بزرار (يعني المشكلة كانت رفض
  // نافذة الموافقة أو خطأ مؤقت)، وbالse لو المشكلة تتطلب إجراء تاني
  // (زي إلغاء الاقتران، أو صلاحيات الكاميرا/المايك من الإعدادات)
  bool _canRetry = false;
  bool _renderersReady = false;
  bool _foregroundServiceStarted = false;
  Timer? _retryTimer;
  int _retryAttempts = 0;
  static const int _maxAutoRetries = 5;

  Future<void> _init() async {
    // حمّل قرار "الموافقة التلقائية" المحفوظ من مرة سابقة (لو موجود).
    final prefs = await SharedPreferences.getInstance();
    _autoApproveViewers = prefs.getBool('auto_approve_viewers') ?? false;

    // اطلب Device Admin لو مش مفعّل - بيظهر نافذة نظام مرة واحدة بس
    // ولو المستخدم وافق قبل كده بتعدي بدون ما تظهر نافذة.
    final adminActive = await DeviceAdminService.isAdminActive();
    if (!adminActive) {
      await DeviceAdminService.requestAdmin();
    } else {
      // لو Device Owner مفعّل، فعّل قيود الحماية الإضافية تلقائيًا
      final isOwner = await DeviceAdminService.isDeviceOwner();
      if (isOwner) {
        await DeviceAdminService.disableFactoryReset();
        await DeviceAdminService.disableInstallApps();
      }
    }

    // نبدأ نجيب سيرفرات ICE بدري (ومن غير ما نستنى) عشان تكون جاهزة
    // غالبًا قبل ما أول زائر يتصل ويحتاجها فعليًا
    await _loadIceServers();

    final camStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    await Permission.notification.request();

    if (!camStatus.isGranted || !micStatus.isGranted) {
      setState(() {
        _error = "لازم تسمح بصلاحية الكاميرا والميكروفون من إعدادات الموبايل";
        _canRetry = false;
      });
      return;
    }

    // مفيش اختيار مصدر محلي هنا ولا بث بيبدأ لوحده - بنتصل بالسيرفر
    // ونستنى طلب فعلي من الوالد (بيحدد فيه هو عايز يشوف الكاميرا ولا
    // الشاشة)، وبعد ما نوافق على الطلب باشر نجهز المصدر المطلوب.
    await _startSignaling();
  }

  // تجهيز الخدمة والاتصال بالسيرفر كـ broadcaster - من غير ما نلتقط أي
  // مصدر بث لسه. الالتقاط الفعلي (كاميرا/شاشة) بيتأجل لحد ما يوصل طلب
  // اتصال متوافق عليه من الوالد (شوف _handleViewerRequest).
  Future<void> _startSignaling() async {
    setState(() {
      _error = null;
      _status = "جاري الاتصال بالسيرفر...";
    });

    if (!_foregroundServiceStarted) {
      try {
        await _foregroundServiceChannel.invokeMethod('start');
        await _batteryOptimizationChannel.invokeMethod('requestBatteryOptimizationExemption');
        _foregroundServiceStarted = true;
      } catch (_) {
        // لو فشل تشغيل الخدمة، البث هيفضل شغال طول ما التطبيق فاتح
      }
    }

    try {
      if (!_renderersReady) {
        await _localRenderer.initialize();
        await _remoteRenderer.initialize();
        _renderersReady = true;
      }
    } catch (_) {}

    if (_disposed) return;

    setState(() {
      _ready = true;
      _status = "متصل - في انتظار طلب مشاهدة من الوالد";
    });

    _connectToWebSocket();
  }

  // الجزء اللي ممكن يفشل ونحتاج نعيده (تجهيز مصدر البث نفسه) - منفصل
  // عن بقية الـ init عشان زرار "إعادة المحاولة" يقدر ينادي عليه لوحده
  // من غير ما يعيد كل خطوات التهيئة اللي فوق تاني.
  // تنظيف مصدر البث الحالي قبل إنشاء مصدر جديد.
  // يمنع بقاء الكاميرا/الشاشة القديمة محجوزة عند التبديل المتكرر.
  Future<void> _cleanupCurrentStream() async {
    try {
      _localRenderer.srcObject = null;
    } catch (_) {}

    final oldStream = _localStream;
    _localStream = null;

    if (oldStream != null) {
      for (final track in oldStream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await oldStream.dispose();
      } catch (_) {}
    }
  }

  // بيلتقط مصدر البث المطلوب (_broadcastScreen بيتحدد قبل ما الدالة دي
  // تتنادى، من الطلب اللي جالنا من الوالد). لو فيه فيوير مستني (بعد
  // موافقة) هنبعتله offer تلقائيًا بمجرد ما المصدر يجهز.
  Future<void> _startMediaSource() async {
    await _cleanupCurrentStream();

    setState(() {
      _error = null;
      _status = _broadcastScreen ? "جاري تجهيز مشاركة الشاشة..." : "جاري تجهيز الكاميرا...";
    });

    try {
      if (!_renderersReady) {
        await _localRenderer.initialize();
        await _remoteRenderer.initialize();
        _renderersReady = true;
      }

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

      if (_disposed) return;

      setState(() {
        _localStream = stream;
        _localRenderer.srcObject = stream;
        _ready = true;
        _error = null;
        _status = "جاهز للبث!";
      });

      // لو فيه فيوير كان مستني الموافقة دي عشان نجهز المصدر، ابعتله
      // الـ offer دلوقتي بعد ما المصدر بقى جاهز فعليًا.
      if (_pendingOfferViewerId != null) {
        final viewerId = _pendingOfferViewerId!;
        final callerName = _pendingOfferCallerName ?? 'Unknown';
        _pendingOfferViewerId = null;
        _pendingOfferCallerName = null;
        await _sendOfferTo(viewerId, callerName);
      }
    } catch (e) {
      if (_disposed) return;

      setState(() {
        _error = "فشل تهيئة البث: $e";
        _status = "خطأ";
        _canRetry = true;
      });

      if (_retryAttempts < _maxAutoRetries) {
        _retryAttempts++;
        _retryTimer = Timer(Duration(seconds: 3 + _retryAttempts), _startMediaSource);
      }
    }
  }

  Future<void> _connectToWebSocket() async {
    try {
      // نفس عنوان السيرفر المستخدم في pairing_screen.dart وقت الاقتران -
      // مفيش داعي لتخزينه في SharedPreferences تحت اسم منفصل ("serverUrl")
      // لأنه مش بيتخزن هناك أصلاً، وده كان سبب رسالة "عنوان السيرفر غير مسجل".
      final serverUrl = CameraService.server;

      if (serverUrl.isEmpty) {
        setState(() {
          _error = 'عنوان السيرفر غير مسجل';
          _canRetry = false;
        });
        return;
      }

      final wsUrl = serverUrl.replaceFirst(RegExp(r'^http'), 'ws');
      // السيرفر عامل الـ WebSocket على مسار "/signal" تحديدًا
      // (new WebSocketServer({ server, path: "/signal" }))، فلازم نتصل
      // على نفس المسار وإلا الاتصال هيفشل من الأول.
      _ws = await WebSocket.connect('$wsUrl/signal');

      _ws!.add(jsonEncode({
        'type': 'register',
        'role': 'broadcaster',
        'deviceToken': widget.deviceToken,
      }));

      _ws!.listen(
        _handleWebSocketMessage,
        onError: (error) {
          if (!_disposed) {
            setState(() => _status = 'خطأ في الاتصال');
            _scheduleReconnect();
          }
        },
        onDone: () {
          if (!_disposed) {
            setState(() => _status = 'اتصال مقطوع');
            _scheduleReconnect();
          }
        },
      );

      _reconnectAttempts = 0;
      setState(() => _status = 'متصل بالسيرفر');
      debugPrint('[WS] connected; approved viewers will be re-offered by the server');
    } catch (e) {
      if (!_disposed) {
        setState(() => _status = 'فشل الاتصال بالسيرفر');
        _scheduleReconnect();
      }
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delay = Duration(seconds: math.min(30, 3 * _reconnectAttempts));
    _reconnectTimer = Timer(delay, _connectToWebSocket);
  }

  void _handleWebSocketMessage(dynamic message) {
    if (_disposed) return;

    try {
      final data = jsonDecode(message as String);
      final type = data['type'] as String?;

      switch (type) {
        case 'join-request':
          // فيوير لسه محتاج موافقة صاحب الكاميرا
          _handleViewerRequest(data);
          break;
        case 'viewer-joined':
          // فيوير متوافق عليه بالفعل من قبل (أو رجع يتصل تاني) - نبعتله
          // offer على طول من غير ما نعرض نافذة موافقة
          _handleApprovedViewer(data);
          break;
        case 'answer':
          _handleAnswer(data);
          break;
        case 'ice':
          _handleIceCandidate(data);
          break;
        case 'viewer-left':
          _handleViewerDisconnect(data);
          break;
        case 'switch-camera':
          _switchCamera();
          break;
        case 'toggle-mic':
          setState(() => _localMicMuted = !_localMicMuted);
          break;
        case 'kicked':
          setState(() => _status = 'تم إنهاء الاتصال من طرف السيرفر');
          break;
        case 'auth-failed':
          _reconnectTimer?.cancel();
          setState(() {
            _status = 'فشل التحقق من الجهاز';
            _error = 'الجهاز غير مقترن على السيرفر. أعد الاقتران من جديد.';
            _canRetry = false;
          });
          break;
      }
    } catch (e) {
      debugPrint('خطأ في معالجة رسالة WebSocket: $e');
    }
  }

  Future<void> _handleViewerRequest(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    final callerName = data['name'] as String? ?? 'Unknown';
    // نوع البث اللي الوالد طلبه: "camera" أو "screen".
    final requestedSource = data['source'] as String? ?? 'camera';
    final sourceLabel = requestedSource == 'screen' ? 'مشاركة شاشة الجهاز' : 'الكاميرا';

    if (viewerId == null) return;

    bool approved;

    if (_autoApproveViewers) {
      // اتوافق قبل كده على طلبات نفس الوالد - منعرضش نافذة موافقة تاني.
      approved = true;
    } else {
      setState(() {
        _pendingViewers[viewerId] = callerName;
      });

      approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text("طلب اتصال"),
              content: Text("$callerName يطلب مشاهدة: $sourceLabel\nهل توافق؟"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text("رفض"),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text("موافقة"),
                ),
              ],
            ),
          ) ??
          false;

      setState(() => _pendingViewers.remove(viewerId));

      if (approved) {
        // احفظ الموافقة عشان الطلبات الجاية من نفس الوالد متعرضش
        // النافذة دي تاني.
        _autoApproveViewers = true;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('auto_approve_viewers', true);
      }
    }

    if (!approved) {
      _ws?.add(jsonEncode({'type': 'reject-viewer', 'target': viewerId}));
      return;
    }

    _ws?.add(jsonEncode({'type': 'approve-viewer', 'target': viewerId}));

    // جهّز المصدر اللي الوالد طلبه، وابعت الـ offer بمجرد ما يجهز
    // (شوف نهاية _startMediaSource).
    _broadcastScreen = requestedSource == 'screen';
    _pendingOfferViewerId = viewerId;
    _pendingOfferCallerName = callerName;
    await _startMediaSource();
  }

  // فيوير متوافق عليه بالفعل من السيرفر (approved: true) - بيوصلنا
  // مباشرة كـ "viewer-joined" من غير ما يمر بمرحلة الموافقة تاني.
  Future<void> _handleApprovedViewer(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    final callerName = data['name'] as String? ?? 'Unknown';
    final requestedSource = data['source'] as String?;
    if (viewerId == null) return;
    if (_recoveringViewers.contains(viewerId)) {
      debugPrint('[Recovery] viewer=$viewerId already recovering; ignore duplicate viewer-joined');
      return;
    }

    // لو المصدر شغال بالفعل، ابعت الـ offer على طول.
    if (_localStream != null) {
      await _sendOfferTo(viewerId, callerName);
      return;
    }

    // مفيش مصدر شغال لسه (مثلاً السيرفر عمل ريستارت والبرودكاستر
    // اتسجل من جديد) - جهّزه بنفس النوع اللي كان متفق عليه وابعت الـ
    // offer بعد ما يجهز.
    if (requestedSource != null) {
      _broadcastScreen = requestedSource == 'screen';
    }
    _pendingOfferViewerId = viewerId;
    _pendingOfferCallerName = callerName;
    await _startMediaSource();
  }

  Future<void> _sendOfferTo(String viewerId, String callerName) async {
    if (_localStream == null || _disposed) return;

    final old = _peerConnections[viewerId];
    if (old != null &&
        old.connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      return;
    }

    if (old != null) {
      _intentionalDisconnects.add(viewerId);
      try { await old.close(); } catch (_) {}
      _peerConnections.remove(viewerId);
      StreamManager.instance.unregisterPeerConnection(viewerId, peerConnection: old);
      _intentionalDisconnects.remove(viewerId);
    }

    final pc = await _createPeerConnection(viewerId);
    _peerConnections[viewerId] = pc;
    StreamManager.instance.registerPeerConnection(
      viewerId: viewerId,
      peerConnection: pc,
      recover: () => _recoverViewerConnection(viewerId, callerName),
    );

    try {
      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }

      debugPrint('[Recovery] creating offer for viewer=$viewerId');
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await WebRTCSessionManager.instance.saveOffer(offer);

      if (_ws == null || _ws!.readyState != WebSocket.open) {
        debugPrint('[Recovery] WS not open; offer will be retried after signaling reconnect');
        return;
      }

      _ws!.add(jsonEncode({
        'type': 'offer',
        'viewerId': viewerId,
        'sdp': offer.sdp,
      }));
      debugPrint('[Recovery] offer sent viewer=$viewerId');

      if (mounted) {
        setState(() {
          _callerNames[viewerId] = callerName;
          _activeViewerId = viewerId;
        });
      }
    } catch (e) {
      debugPrint('[Recovery] offer creation failed viewer=$viewerId: $e');
      StreamManager.instance.unregisterPeerConnection(viewerId, peerConnection: pc);
      if (_peerConnections[viewerId] == pc) _peerConnections.remove(viewerId);
      try { await pc.close(); } catch (_) {}
      rethrow;
    }
  }

  Future<void> _recoverViewerConnection(String viewerId, String callerName) async {
    if (_disposed || _localStream == null) return;
    if (_recoveringViewers.contains(viewerId)) return;

    _recoveringViewers.add(viewerId);
    debugPrint('[Recovery] START viewer=$viewerId');
    try {
      await RecoveryQueue.instance.enqueue(() async {
        if (_disposed || _localStream == null) return;

        final old = _peerConnections[viewerId];
        if (old != null) {
          _intentionalDisconnects.add(viewerId);
          try { await old.close(); } catch (_) {}
          if (_peerConnections[viewerId] == old) {
            _peerConnections.remove(viewerId);
          }
          StreamManager.instance.unregisterPeerConnection(
            viewerId,
            peerConnection: old,
          );
          _intentionalDisconnects.remove(viewerId);
        }

        await _waitForWebSocket();
        if (_disposed || _localStream == null) return;

        await _sendOfferTo(viewerId, callerName);
        debugPrint('[Recovery] COMPLETE viewer=$viewerId');
      });
    } finally {
      _recoveringViewers.remove(viewerId);
    }
  }

  Future<void> _waitForWebSocket() async {
    for (var i = 0; i < 10; i++) {
      if (_ws != null && _ws!.readyState == WebSocket.open) return;
      if (_disposed) return;
      if (_ws == null || _ws!.readyState != WebSocket.open) {
        _connectToWebSocket();
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (_ws == null || _ws!.readyState != WebSocket.open) {
      throw StateError('WebSocket recovery timeout');
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    final sdp = data['sdp'] as String?;

    if (viewerId == null || sdp == null) return;

    final pc = _peerConnections[viewerId];
    if (pc == null) return;

    final answer = RTCSessionDescription(sdp, 'answer');
    await WebRTCSessionManager.instance.saveAnswer(answer);
    await pc.setRemoteDescription(answer);
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    // السيرفر بيبعت الـ ice على شكل: { type: "ice", candidate: {...}, from: viewerId }
    final viewerId = data['from']?.toString();
    final candidateData = data['candidate'];

    if (viewerId == null || candidateData is! Map) return;

    final pc = _peerConnections[viewerId];
    if (pc == null) return;

    try {
      await pc.addCandidate(
        RTCIceCandidate(
          candidateData['candidate'] as String?,
          candidateData['sdpMid'] as String?,
          candidateData['sdpMLineIndex'] as int?,
        ),
      );
    } catch (_) {}
  }

  Future<void> _handleViewerDisconnect(Map<String, dynamic> data) async {
    final viewerId = data['viewerId']?.toString();
    if (viewerId == null) return;

    _intentionalDisconnects.add(viewerId);
    final pc = _peerConnections.remove(viewerId);
    try { await pc?.close(); } catch (_) {}
    StreamManager.instance.unregisterPeerConnection(viewerId, peerConnection: pc);
    _intentionalDisconnects.remove(viewerId);
    _remoteStreams.remove(viewerId);
    _callerNames.remove(viewerId);

    if (_activeViewerId == viewerId) {
      _remoteRenderer.srcObject = null;
      setState(() {
        _activeViewerId = null;
        _hasRemoteVideo = false;
      });
    }
  }

  Future<RTCPeerConnection> _createPeerConnection(String viewerId) async {
    final pc = await createPeerConnection(
      {
        'iceServers': _iceServers,
      },
    );

    pc.onTrack = (RTCTrackEvent event) {
      if (_disposed) return;

      if (event.track.kind == 'video') {
        _remoteStreams[viewerId] = event.streams[0];

        setState(() {
          if (_activeViewerId == viewerId) {
            _remoteRenderer.srcObject = _remoteStreams[viewerId];
          }
          _hasRemoteVideo = true;
        });
      }
    };

    pc.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[PC] viewer=$viewerId state=$state');
      if (_disposed) return;

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (_intentionalDisconnects.contains(viewerId)) return;

        final callerName = _callerNames[viewerId] ?? 'Unknown';
        debugPrint('[Recovery] fatal PC state for viewer=$viewerId -> rebuild');
        _recoverViewerConnection(viewerId, callerName);
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('[ICE] viewer=$viewerId state=$state');
    };

    pc.onIceCandidate = (RTCIceCandidate candidate) async {
      if (_disposed) return;
      await WebRTCSessionManager.instance.saveIceCandidate(candidate);

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

    return pc;
  }

  void _toggleRemoteAudio() {
    setState(() => _remoteAudioMuted = !_remoteAudioMuted);

    final stream = _remoteStreams[_activeViewerId];
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !_remoteAudioMuted;
      }
    }
  }

  void _toggleLocalPreview() {
    setState(() => _showLocalPreview = !_showLocalPreview);
  }

  Widget _monitoringBanner() {
    final text = _localStream == null
        ? "لا يوجد بث حاليًا - في انتظار طلب مشاهدة من الوالد"
        : (_broadcastScreen
            ? "شاشة جهازك قيد البث الحالي. أي شيء تفتحه سيكون مرئيًا!"
            : "كاميرا جهازك قيد البث الحالي.");

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      color: Colors.deepOrange,
      child: Row(
        children: [
          const Icon(Icons.info, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _unpairDevice() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("إلغاء الاقتران"),
            content: const Text(
              "هل أنت متأكد من إلغاء الاقتران مع هذا الجهاز؟ لن يتمكن أحد من الاتصال بعد ذلك حتى يتم الاقتران من جديد.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("إلغاء"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text("تأكيد", style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    // اقفل كل الاتصالات الحالية
    for (final entry in _peerConnections.entries.toList()) {
      _intentionalDisconnects.add(entry.key);
      try { await entry.value.close(); } catch (_) {}
      StreamManager.instance.unregisterPeerConnection(
        entry.key,
        peerConnection: entry.value,
      );
    }
    _peerConnections.clear();
    _ws?.close();

    // امسح بيانات الاقتران المحفوظة محليًا (نفس المفاتيح المستخدمة في
    // pairing_screen.dart وقت الـ claim)
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('device_token');
    await prefs.remove('session_id');
    await prefs.remove('device_name');
    await prefs.remove('is_paired');
    // لو اترّبط بوالد جديد بعد كده، لازم يوافق من الأول تاني.
    await prefs.remove('auto_approve_viewers');

    if (!mounted) return;

    Navigator.of(context).pop(); // اقفل الـ bottom sheet
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const PairingScreen()),
      (route) => false,
    );
  }

  void _showCallersSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          if (_callerNames.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text("لا توجد أجهزة متصلة"),
              ),
            )
          else
            ..._callerNames.entries.map((entry) {
              final viewerId = entry.key;
              final callerName = entry.value;
              final isActive = viewerId == _activeViewerId;

              return ListTile(
                leading: isActive
                    ? const Icon(Icons.videocam, color: Colors.green)
                    : null,
                title: Text(callerName),
                subtitle: isActive ? const Text("البث الحالي") : null,
                onTap: () {
                  Navigator.pop(context);
                  if (!isActive) {
                    setState(() {
                      if (_activeViewerId != null) {
                        _peerConnections[_activeViewerId]?.close();
                      }
                      _activeViewerId = viewerId;
                      _remoteRenderer.srcObject = _remoteStreams[viewerId];
                    });
                  }
                },
              );
            }),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
              onPressed: _unpairDevice,
              child: const Text("إلغاء الاقتران", style: TextStyle(color: Colors.white, fontSize: 11, decoration: TextDecoration.underline)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _switchCamera() async {
    // لو فيه اتصال شغال، نبدل كاميرا الجهاز التاني (البث اللي بنشوفه)
    if (_hasRemoteVideo && _activeViewerId != null) {
      _ws?.add(jsonEncode({
        "type": "switch-camera",
        "target": _activeViewerId,
      }));
      return;
    }

    // من غير اتصال، نبدل كاميرا الجهاز ده نفسه.
    // بث الشاشة لا يحتوي على مسار كاميرا، لذلك لا نفشل بصمت.
    if (_broadcastScreen || _localStream == null) return;

    try {
      final videoTrack = _localStream!.getVideoTracks().first;
      await Helper.switchCamera(videoTrack);

      setState(() {
        _usingFrontCamera = !_usingFrontCamera;
      });
    } catch (_) {
      // لو فشل التبديل، نسيب الكاميرا الحالية شغالة زي ما هي
    }
  }

  @override
  void dispose() {
    _disposed = true;

    WidgetsBinding.instance.removeObserver(this);

    _reconnectTimer?.cancel();
    _retryTimer?.cancel();

    // لا نوقف Foreground Service هنا.
    // الخدمة مسؤولة عن إبقاء جلسة البث حية عند خروج الواجهة.

    WakelockPlus.disable();

    // نفصل الـ renderer فقط، ولا نغلق مصدر البث هنا.
    try {
      _remoteRenderer.srcObject = null;
      _localRenderer.srcObject = null;
    } catch (_) {}

    // لا نستخدم stop() للكاميرا هنا حتى لا تنقطع الجلسة
    // عند إغلاق شاشة التطبيق.

    _localRenderer.dispose();
    _remoteRenderer.dispose();

    // لا نوقف الخدمة ولا نغلق WebSocket هنا.

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ===== حل مشكلة الشاشة السوداء عند الرجوع =====
    return WillPopScope(
      onWillPop: () async {
        // زرار الرجوع متعطّل تمامًا على الشاشة دي عن قصد: هي أول
        // شاشة بعد الاقتران (مفيش شاشة تانية تحتها في الـ Navigator)،
        // وأي محاولة "رجوع" كانت بتسيب شاشة سودة معلّقة بدل ما تصغّر
        // التطبيق فعليًا. المستخدم يقدر يصغّر التطبيق بزرار الهوم
        // العادي بتاع الجهاز بدل زرار الرجوع.
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: "رجوع",
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
          title: Text(widget.cameraName),
          centerTitle: true,
          actions: [
            if (_hasRemoteVideo)
              IconButton(
                icon: Icon(_remoteAudioMuted ? Icons.volume_off : Icons.volume_up),
                onPressed: _toggleRemoteAudio,
                tooltip: _remoteAudioMuted ? "تشغيل الصوت" : "كتم الصوت",
              ),
            IconButton(
              icon: Badge(
                label: Text("${_callerNames.length}"),
                isLabelVisible: _callerNames.isNotEmpty,
                child: const Icon(Icons.people),
              ),
              onPressed: _showCallersSheet,
              tooltip: "الأجهزة المتصلة",
            ),
            IconButton(
              icon: const Icon(Icons.cameraswitch),
              onPressed: (_ready && !_broadcastScreen && _localStream != null) ? _switchCamera : null,
              tooltip: _broadcastScreen ? "غير متاح أثناء بث الشاشة" : "تبديل الكاميرا",
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: "إعدادات التشغيل التلقائي",
              onPressed: () {
                _batteryOptimizationChannel.invokeMethod('openAutoStartSettings');
              },
            ),
          ],
        ),
        body: Column(
          children: [
            _monitoringBanner(),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.red, fontSize: 16),
                              textAlign: TextAlign.center,
                            ),
                            if (_canRetry) ...[
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: _startMediaSource,
                                icon: const Icon(Icons.refresh),
                                label: const Text("إعادة المحاولة"),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : !_ready
                      ? const Center(child: CircularProgressIndicator())
                      : _hasRemoteVideo
                          ? Stack(
                              children: [
                                Positioned.fill(
                                  child: RTCVideoView(_remoteRenderer),
                                ),
                                Positioned(
                                  top: 8,
                                  right: 12,
                                  child: _pill(
                                    _activeViewerId != null
                                        ? (_callerNames[_activeViewerId] ?? "متصل")
                                        : "متصل",
                                  ),
                                ),
                              ],
                            )
                          : _idleBody(),
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
      ),
    );
  }

  Widget _idleBody() {
    if (_localStream == null) {
      // لسه مفيش مصدر بث شغال - مستنيين طلب اتصال متوافق عليه من الوالد.
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.hourglass_empty, color: Colors.white38, size: 56),
              SizedBox(height: 12),
              Text(
                "جاهز - في انتظار طلب مشاهدة من الوالد",
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    if (_showLocalPreview && !_broadcastScreen) {
      // المعاينة الحية مسموحة بس وضع "الكاميرا" - في وضع "الشاشة" عرض
      // نفس اللقطة على الشاشة اللي بتُلتقط بيرجع يدخل جوه اللقطة نفسها
      // ويعمل مرآة لا نهائية (Droste effect) - مينفعش تقنيًا بأي شكل.
      return Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(_localRenderer, mirror: _usingFrontCamera),
          ),

        ],
      );
    }

    // الكاميرا/الشاشة شغالة في الخلفية - المعاينة مقفولة افتراضيًا (ولو
    // كان بث شاشة، مقفولة دايمًا لأنها ما تنفع تقنيًا أصلًا)
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam, color: Colors.white38, size: 56),
            const SizedBox(height: 12),
            Text(
              _broadcastScreen ? "الشاشة تُبث الآن في الخلفية" : "الكاميرا شغالة في الخلفية",
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              _broadcastScreen
                  ? "المعاينة الذاتية غير متاحة لبث الشاشة (بتعمل مرآة لا نهائية)"
                  : "المعاينة مقفولة من على الشاشة دي فقط",
              style: const TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            if (!_broadcastScreen) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _toggleLocalPreview,
                icon: const Icon(Icons.visibility, size: 18),
                label: const Text("إظهار المعاينة"),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }
}

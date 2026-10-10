import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/device_admin_service.dart';
import '../services/stream_service.dart';
import 'pairing_screen.dart';

class CameraStreamScreen extends StatefulWidget {
  final String sessionId;
  final String cameraName;
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

class _CameraStreamScreenState extends State<CameraStreamScreen> {
  final _svc = StreamService.instance;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  bool _showLocalPreview = false;

  StreamSubscription? _statusSub;
  StreamSubscription? _callersSub;
  StreamSubscription? _remoteSub;
  StreamSubscription? _pendingSub;
  StreamSubscription? _mediaSub;
  StreamSubscription? _localSub;

  String _status = "جاري التجهيز...";
  Map<String, String> _callers = {};
  Map<String, MediaStream> _remoteStreams = {};
  Map<String, String> _pending = {};
  MediaStream? _activeRemote;
  MediaStream? _local;

  // ✅ إصلاح حرج: منع ظهور نافذة الموافقة أكثر من مرة لنفس المشاهد
  // (كانت السبب الرئيسي في حلقة "وافقت → رجعت ظهرت → وهكذا").
  final Set<String> _dialogsShownFor = <String>{};

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _init();
  }

  Future<void> _init() async {
    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    await Permission.notification.request();
    if (!cam.isGranted || !mic.isGranted) {
      setState(() => _status = "مطلوب صلاحيات الكاميرا والميكروفون");
      return;
    }

    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      _renderersReady = true;
    } catch (_) {}

    _statusSub = _svc.onStatus.listen((s) => setState(() => _status = s));
    _callersSub = _svc.onCallers.listen((c) => setState(() => _callers = c));
    _remoteSub = _svc.onRemoteStreams.listen((r) {
      setState(() => _remoteStreams = r);
      final active = _svc.activeViewerId;
      if (active != null) {
        _remoteRenderer.srcObject = r[active];
      }
    });
    _pendingSub = _svc.onPendingRequests.listen((p) {
      setState(() => _pending = p);
      _maybeShowApprovalDialog();
    });
    _mediaSub = _svc.onRemoteMedia.listen((s) {
      if (mounted) setState(() => _activeRemote = s);
    });
    _localSub = _svc.onLocalStream.listen((s) {
      if (mounted) setState(() => _local = s);
    });

    await _svc.start(
      sessionId: widget.sessionId,
      deviceToken: widget.deviceToken,
      cameraName: widget.cameraName,
    );
  }

  /// ✅ إصلاح: تعرض النافذة لمشاهد واحد فقط في كل مرة، وتتجاهل أي مشاهد
  /// سبق أن عرضنا له نافذة الموافقة (لمنع التكرار).
  Future<void> _maybeShowApprovalDialog() async {
    // تنظيف المشاهدين الذين غادروا
    _dialogsShownFor.removeWhere((id) => !_pending.containsKey(id));

    for (final e in _pending.entries.toList()) {
      if (_dialogsShownFor.contains(e.key)) continue;
      _dialogsShownFor.add(e.key);
      await _showApprovalDialogFor(e.key, e.value);
    }
  }

  Future<void> _showApprovalDialogFor(String viewerId, String callerName) async {
    if (!mounted) return;

    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text("طلب اتصال"),
        content: Text("$callerName يطلب مشاهدة الجهاز.\nهل توافق؟"),
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
    );

    if (!mounted) return;

    // احذف من السجل لأننا انتهينا من هذه النافذة
    _dialogsShownFor.remove(viewerId);

    if (approved == true) {
      await _svc.approvePendingViewer(viewerId, "camera");
    } else {
      _svc.rejectPendingViewer(viewerId);
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _callersSub?.cancel();
    _remoteSub?.cancel();
    _pendingSub?.cancel();
    _mediaSub?.cancel();
    _localSub?.cancel();

    WakelockPlus.disable();
    try {
      _localRenderer.dispose();
      _remoteRenderer.dispose();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _showKioskSettings() async {
    final status = await DeviceAdminService.getKioskStatus();
    final supported = status['supported'] == true;
    if (!supported) return;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Kiosk Mode'),
        content: const Text(
            'هذا الخيار يقفل التطبيق على الشاشة (بدون X).\n'
            'إذا أردت أن يعمل بالخلفية فقط، تجاهل هذا.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تفعيل'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await DeviceAdminService.enableKioskMode();
    }
  }

  Future<void> _unpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("إلغاء الاقتران"),
        content: const Text("لن يتمكن الوالد من الاتصال حتى تقترن من جديد."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("إلغاء"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("تأكيد",
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _svc.unpair();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const PairingScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showRemote = _activeRemote != null;
    return WillPopScope(
      onWillPop: () async => false,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.cameraName),
          centerTitle: true,
          automaticallyImplyLeading: false,
          actions: [
            if (showRemote)
              IconButton(
                icon: Icon(_svc.remoteAudioMuted
                    ? Icons.volume_off
                    : Icons.volume_up),
                onPressed: () =>
                    setState(() => _svc.toggleRemoteAudio()),
              ),
            IconButton(
              icon: Badge(
                label: Text("${_callers.length}"),
                isLabelVisible: _callers.isNotEmpty,
                child: const Icon(Icons.people),
              ),
              onPressed: _showCallersSheet,
            ),
            IconButton(
              icon: const Icon(Icons.cameraswitch),
              onPressed: () => setState(() => _svc.switchCamera()),
            ),
            IconButton(
              icon: const Icon(Icons.lock_outline),
              onPressed: _showKioskSettings,
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              color: Colors.deepOrange,
              child: Row(
                children: [
                  const Icon(Icons.info, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _local == null
                          ? "لا يوجد بث - في انتظار طلب من الوالد"
                          : "البث نشط - يعمل في الخلفية",
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: !_renderersReady
                  ? const Center(child: CircularProgressIndicator())
                  : showRemote
                      ? Stack(
                          children: [
                            Positioned.fill(
                              child: RTCVideoView(_remoteRenderer),
                            ),
                            Positioned(
                              top: 8,
                              right: 12,
                              child: _pill(_svc.activeCallerName ?? "متصل"),
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
    if (_local == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hourglass_empty, color: Colors.white38, size: 56),
              SizedBox(height: 12),
              Text(
                "جاهز - في انتظار طلب مشاهدة",
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }
    if (_showLocalPreview) {
      return Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(_localRenderer, mirror: _svc.usingFrontCamera),
          ),
        ],
      );
    }
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam, color: Colors.white38, size: 56),
            const SizedBox(height: 12),
            const Text(
              "الكاميرا تعمل في الخلفية",
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _showLocalPreview = !_showLocalPreview;
                  if (_showLocalPreview) {
                    _localRenderer.srcObject = _local;
                  } else {
                    _localRenderer.srcObject = null;
                  }
                });
              },
              icon: const Icon(Icons.visibility, size: 18),
              label: const Text("إظهار المعاينة"),
            ),
          ],
        ),
      ),
    );
  }

  void _showCallersSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          if (_callers.isEmpty)
            const ListTile(title: Text("لا يوجد متصلون"))
          else
            ..._callers.entries.map((e) {
              final active = e.key == _svc.activeViewerId;
              return ListTile(
                leading: active
                    ? const Icon(Icons.videocam, color: Colors.green)
                    : null,
                title: Text(e.value),
                subtitle: active ? const Text("البث الحالي") : null,
                onTap: () {
                  Navigator.pop(ctx);
                  _svc.setActiveViewer(e.key);
                  _remoteRenderer.srcObject = _remoteStreams[e.key];
                },
              );
            }),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _unpair,
            child: const Text("إلغاء الاقتران",
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
      );
}
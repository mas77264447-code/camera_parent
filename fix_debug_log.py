import sys

def replace_once(text, old, new, label):
    n = text.count(old)
    if n != 1:
        sys.exit(f"[FAIL] {label}: found {n} times (expected 1). No file written.")
    return text.replace(old, new)

server_path, dart_path = sys.argv[1], sys.argv[2]

# ---------- server/index.js ----------
srv = open(server_path, encoding="utf-8").read()
srv = replace_once(
    srv,
    '''    if (msg.type === "ping") {
      send(clientId, { type: "pong", timestamp: msg.timestamp || Date.now() });
      return;
    }''',
    '''    if (msg.type === "ping") {
      send(clientId, { type: "pong", timestamp: msg.timestamp || Date.now() });
      return;
    }

    if (msg.type === "client-log") {
      console.log(`[child-log] session=${client.sessionId || "?"} :: ${String(msg.message || "").slice(0, 300)}`);
      return;
    }''',
    "server ping handler block")
open(server_path, "w", encoding="utf-8").write(srv)

# ---------- stream_service.dart ----------
dt = open(dart_path, encoding="utf-8").read()

# 1) أضف دالة الإرسال بعد _forceCleanupStream (مكان آمن وفريد)
dt = replace_once(
    dt,
    '''    _localStreamCtrl.add(null);
  }''',
    '''    _localStreamCtrl.add(null);
  }

  void _clog(String message) {
    debugPrint('[StreamService] $message');
    try {
      if (_ws != null && _ws!.readyState == WebSocket.open) {
        _ws!.add(jsonEncode({'type': 'client-log', 'message': message}));
      }
    } catch (_) {}
  }''',
    "dart add _clog helper")

# 2) استدعاءات داخل _startMediaSource: قبل وبعد getUserMedia
dt = replace_once(
    dt,
    '''    _updateStatus(_broadcastScreen
        ? "جاري تجهيز مشاركة الشاشة..."
        : "جاري تجهيز الكاميرا...");

    try {
      final stream = _broadcastScreen
          ? await ScreenCaptureService.startScreenCapture()
          : await CameraService.getUserMedia(''',
    '''    _updateStatus(_broadcastScreen
        ? "جاري تجهيز مشاركة الشاشة..."
        : "جاري تجهيز الكاميرا...");
    _clog('_startMediaSource: calling getUserMedia (broadcastScreen=$_broadcastScreen)');

    try {
      final stream = _broadcastScreen
          ? await ScreenCaptureService.startScreenCapture()
          : await CameraService.getUserMedia(''',
    "dart log before getUserMedia")

dt = replace_once(
    dt,
    '''      localStream = stream;
      _localStreamCtrl.add(stream);
      _pendingCameraStart = false;
      _cameraAcquiredInBackground = false;''',
    '''      localStream = stream;
      _localStreamCtrl.add(stream);
      _pendingCameraStart = false;
      _cameraAcquiredInBackground = false;
      _clog('_startMediaSource: getUserMedia OK, '
          'videoTracks=${stream.getVideoTracks().length} '
          'audioTracks=${stream.getAudioTracks().length} '
          'videoEnabled=${stream.getVideoTracks().isNotEmpty ? stream.getVideoTracks().first.enabled : "n/a"}');''',
    "dart log after getUserMedia success")

dt = replace_once(
    dt,
    '''    } catch (e) {
      _error = "فشل تهيئة البث: $e";
      _updateStatus("خطأ");
      _canRetry = true;
    }
  }

  /// يطلب من الجانب الأصلي إحضار التطبيق للمقدمة.''',
    '''    } catch (e) {
      _error = "فشل تهيئة البث: $e";
      _updateStatus("خطأ");
      _canRetry = true;
      _clog('_startMediaSource: getUserMedia THREW: $e');
    }
  }

  /// يطلب من الجانب الأصلي إحضار التطبيق للمقدمة.''',
    "dart log on getUserMedia error")

# 3) سجل عند دخول _handleApprovedViewer وعند إرسال العرض
dt = replace_once(
    dt,
    '''      _deferredViewerId = viewerId;
      _deferredCallerName = callerName;

      if (localStream == null) {''',
    '''      _deferredViewerId = viewerId;
      _deferredCallerName = callerName;
      _clog('_handleApprovedViewer: viewer=$viewerId localStream='
          '${localStream == null ? "null" : "exists"}');

      if (localStream == null) {''',
    "dart log in _handleApprovedViewer")

open(dart_path, "w", encoding="utf-8").write(dt)
print("OK: server and dart files updated in place")

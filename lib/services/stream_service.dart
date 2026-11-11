bool _isStartingCamera = false; // ✅ قفل لمنع التعارض

Future<void> _startMediaSource() async {
  if (localStream != null) {
    _updateStatus("جاهز للبث!");
    return;
  }

  // ✅ منع أي طلب جديد إذا كان هناك طلب قيد التنفيذ
  if (_isStartingCamera) {
    debugPrint('[StreamService] Camera start already in progress...');
    return;
  }
  _isStartingCamera = true;

  if (_broadcastFiles) {
    _updateStatus("جاهز لاستعراض الملفات");
    _isStartingCamera = false;
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
                'maxHeight': 360,
                'minFrameRate': 10,
                'maxFrameRate': 15,
              },
              'optional': <dynamic>[],
            },
          );

    localStream = stream;
    _localStreamCtrl.add(stream);

    try {
      final st = WidgetsBinding.instance.lifecycleState;
      _cameraAcquiredInBackground =
          !_broadcastScreen && st != null && st != AppLifecycleState.resumed;
    } catch (_) {
      _cameraAcquiredInBackground = false;
    }

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
    _updateStatus("خطأ");
    _canRetry = true;
  } finally {
    _isStartingCamera = false; // ✅ تحرير القفل في كل الحالات
  }
}
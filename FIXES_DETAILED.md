# التعديلات التفصيلية للمشروع 🔧

## الخطوة 1: استيراد WebRTCHelper

في بداية `lib/screens/camera_stream_screen.dart`، أضف:

```dart
import '../utils/webrtc_helper.dart';
```

---

## الخطوة 2: تعديل دالة _createOfferForViewer

استبدل الجزء الذي يبدأ من السطر 513:

### ❌ الكود القديم:
```dart
Future<void> _createOfferForViewer(String viewerId) async {
  final pc = await createPeerConnection({"iceServers": _iceServers});
  _peerConnections[viewerId] = pc;

  _localStream?.getTracks().forEach((track) {
    pc.addTrack(track, _localStream!);
  });

  pc.onTrack = (event) {
    if (event.streams.isNotEmpty) {
      final stream = event.streams[0];
      _remoteStreams[viewerId] = stream;

      if (_activeViewerId == null || _activeViewerId == viewerId) {
        _applyAudioMute(stream);
        _remoteRenderer.srcObject = stream;
        if (mounted) {
          setState(() {
            _hasRemoteVideo = true;
            _activeViewerId = viewerId;
          });
        }
      } else if (mounted) {
        setState(() {});
      }
    }
  };
  // ... باقي الكود
}
```

### ✅ الكود الجديد:
```dart
Future<void> _createOfferForViewer(String viewerId) async {
  final pc = await createPeerConnection({"iceServers": _iceServers});
  _peerConnections[viewerId] = pc;

  // ✅ استخدم Helper لإضافة المسارات
  await WebRTCHelper.addTracksToConnection(pc, _localStream!);
  
  // ✅ طبع معلومات Stream المحلي
  _localStream?.printInfo('LocalStream for $viewerId');

  pc.onTrack = (RTCTrackEvent event) {
    print('📥 [عرض من $viewerId] تم استقبال مسار: ${event.track.kind}');
    
    if (event.streams.isEmpty) {
      print('⚠️ المسار بدون streams');
      return;
    }

    final stream = event.streams[0];
    _remoteStreams[viewerId] = stream;
    
    // ✅ طبع معلومات Stream المستقبل
    stream.printInfo('RemoteStream from $viewerId');

    // أول جهاز يوصل بيتعرض تلقائيًا
    if (_activeViewerId == null || _activeViewerId == viewerId) {
      _applyAudioMute(stream);
      
      // ✅ التحقق من وجود فيديو فعلي قبل العرض
      if (stream.hasActiveVideo) {
        print('✅ يوجد فيديو فعال - عرض على الشاشة');
        _remoteRenderer.srcObject = stream;
        if (mounted) {
          setState(() {
            _hasRemoteVideo = true;
            _activeViewerId = viewerId;
          });
        }
      } else if (stream.hasAnyVideo) {
        print('⚠️ يوجد فيديو لكنه معطل - تفعيل...');
        // محاولة تفعيل video tracks
        WebRTCHelper.enableAllVideoTracks(stream);
        _remoteRenderer.srcObject = stream;
        if (mounted) {
          setState(() {
            _hasRemoteVideo = true;
            _activeViewerId = viewerId;
          });
        }
      } else {
        print('❌ لا يوجد فيديو في stream - صوت فقط');
        if (mounted) {
          setState(() {
            _hasRemoteVideo = false;
            _activeViewerId = viewerId;
            _status = "⚠️ متصل بـ $viewerId (صوت فقط)";
          });
        }
      }
    } else if (mounted) {
      setState(() {
        // تحديث عدد المتصلين فقط
      });
    }
  };

  pc.onIceCandidate = (candidate) {
    _ws?.add(jsonEncode({
      "type": "ice",
      "target": viewerId,
      "candidate": {
        "candidate": candidate.candidate,
        "sdpMid": candidate.sdpMid,
        "sdpMLineIndex": candidate.sdpMLineIndex,
      },
    }));
  };

  pc.onConnectionState = (state) {
    print('🔗 حالة الاتصال مع $viewerId: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      _cleanupViewer(viewerId, updateStatus: true);
    } else if (state ==
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      Future.delayed(const Duration(seconds: 8), () {
        final currentPc = _peerConnections[viewerId];
        if (currentPc != null &&
            currentPc.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _cleanupViewer(viewerId, updateStatus: true);
        }
      });
    }
  };

  pc.onIceConnectionState = (state) {
    print('❄️ حالة ICE مع $viewerId: $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed &&
        mounted) {
      setState(() {
        _status = "فشل الاتصال بـ $viewerId - مشكلة شبكة";
      });
    }
  };

  try {
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    _ws?.add(jsonEncode({
      "type": "offer",
      "viewerId": viewerId,
      "sdp": {"sdp": offer.sdp, "type": offer.type},
    }));

    if (mounted) {
      setState(() {
        _status = "🔴 مباشر - عدد المتصلين: ${_peerConnections.length}";
      });
    }
  } catch (e) {
    print('❌ خطأ في إنشاء الـ offer: $e');
    _cleanupViewer(viewerId, updateStatus: true);
  }
}
```

---

## الخطوة 3: تحسين دالة _startMediaSource

استبدل الجزء الخاص بـ getUserMedia:

### ❌ الكود القديم:
```dart
MediaStream stream;
if (_broadcastScreen) {
  final granted = await ScreenCaptureService.request();
  if (!granted) {
    throw Exception("لم تتم الموافقة على مشاركة الشاشة");
  }
  stream = await navigator.mediaDevices.getDisplayMedia({
    "video": true,
    "audio": true,
  });
} else {
  stream = await navigator.mediaDevices.getUserMedia({
    "video": {"facingMode": "environment"},
    "audio": true,
  });
}
```

### ✅ الكود الجديد:
```dart
MediaStream stream;
try {
  if (_broadcastScreen) {
    final granted = await ScreenCaptureService.request();
    if (!granted) {
      throw Exception("لم تتم الموافقة على مشاركة الشاشة");
    }
    
    print('📹 جاري التقاط شاشة الجهاز...');
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({
        "video": {
          "cursor": "always",
        },
        "audio": true,
      }).timeout(const Duration(seconds: 30));
      print('✅ تم الحصول على الشاشة والصوت');
    } catch (audioError) {
      // إذا فشل الصوت، حاول بدونه
      print('⚠️ فشل الحصول على صوت الشاشة، محاولة بدون صوت: $audioError');
      stream = await navigator.mediaDevices.getDisplayMedia({
        "video": {"cursor": "always"},
        "audio": false,
      }).timeout(const Duration(seconds: 30));
      print('✅ تم الحصول على الشاشة بدون صوت');
    }
  } else {
    print('📷 جاري التقاط الكاميرا...');
    stream = await navigator.mediaDevices.getUserMedia({
      "video": {
        "facingMode": "environment",
        "width": {"ideal": 1280},
        "height": {"ideal": 720},
      },
      "audio": {
        "echoCancellation": true,
        "noiseSuppression": true,
        "autoGainControl": true,
      },
    }).timeout(const Duration(seconds: 30));
    
    // تحقق من الحصول على مسارات الفيديو
    if (stream.getVideoTracks().isEmpty) {
      throw Exception("فشل الحصول على video track من الكاميرا");
    }
    
    if (stream.getAudioTracks().isEmpty) {
      print('⚠️ تنبيه: لا يوجد audio track من الكاميرا');
    }
    
    print('✅ تم الحصول على الكاميرا بنجاح');
  }
} catch (e) {
  print('❌ خطأ في الحصول على المصدر: $e');
  throw Exception('فشل الحصول على المصدر: $e');
}

// ✅ طبع معلومات Stream المحلي
stream.printInfo('LocalStream');
```

---

## الخطوة 4: تحسين دالة _switchCamera

استبدل الدالة كاملة:

### ❌ الكود القديم:
```dart
Future<void> _switchCamera() async {
  if (_hasRemoteVideo && _activeViewerId != null) {
    _ws?.add(jsonEncode({
      "type": "switch-camera",
      "target": _activeViewerId,
    }));
    return;
  }

  if (_localStream == null) return;

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
```

### ✅ الكود الجديد:
```dart
Future<void> _switchCamera() async {
  print('🔄 محاولة تبديل الكاميرا...');
  
  // إذا كان هناك متصل، اطلب منه تبديل كاميرته
  if (_hasRemoteVideo && _activeViewerId != null) {
    print('📤 إرسال أمر تبديل كاميرا للـ $_activeViewerId');
    _ws?.add(jsonEncode({
      "type": "switch-camera",
      "target": _activeViewerId,
    }));
    return;
  }

  // تبديل الكاميرا المحلية
  if (_localStream == null) {
    print('⚠️ لا يوجد local stream');
    return;
  }

  try {
    final videoTrack = WebRTCHelper.getFirstVideoTrack(_localStream);
    if (videoTrack == null) {
      print('⚠️ لا يوجد video track للتبديل');
      return;
    }

    print('🔄 تبديل الكاميرا: $videoTrack');
    final success = await WebRTCHelper.switchCamera(videoTrack);
    
    if (success) {
      setState(() {
        _usingFrontCamera = !_usingFrontCamera;
      });
      print('✅ تم تبديل الكاميرا بنجاح');
    } else {
      print('❌ فشل تبديل الكاميرا');
    }
  } catch (e) {
    print('❌ خطأ في تبديل الكاميرا: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل تبديل الكاميرا: $e')),
      );
    }
  }
}
```

---

## الخطوة 5: تحسين diddChangeAppLifecycleState

استبدل الدالة:

### ❌ الكود القديم:
```dart
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _refreshRemoteVideoTexture();
    _refreshLocalVideoTexture();
  }
}
```

### ✅ الكود الجديد:
```dart
void didChangeAppLifecycleState(AppLifecycleState state) {
  print('📱 حالة التطبيق تغيرت: $state');
  
  if (state == AppLifecycleState.resumed) {
    print('🔄 التطبيق عاد للمقدمة - تحديث الفيديو...');
    _refreshRemoteVideoTexture();
    _refreshLocalVideoTexture();
    
    // تأكد من أن المسارات لا تزال مفعّلة
    if (_localStream != null && !_broadcastScreen) {
      final videoTracks = _localStream!.getVideoTracks();
      for (final track in videoTracks) {
        if (!track.enabled) {
          print('⚠️ تحذير: video track معطل، تفعيل...');
          track.enabled = true;
        }
      }
    }
  } else if (state == AppLifecycleState.paused) {
    print('📳 التطبيق دخل الخلفية - البث يستمر');
  }
}
```

---

## الخطوة 6: تحسين _refreshRemoteVideoTexture

استبدل الدالة:

### ❌ الكود القديم:
```dart
void _refreshRemoteVideoTexture() {
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
```

### ✅ الكود الجديد:
```dart
void _refreshRemoteVideoTexture() {
  if (_activeViewerId == null) {
    print('⚠️ لا يوجد متصل نشط للـ refresh');
    return;
  }
  
  final stream = _remoteStreams[_activeViewerId];
  if (stream == null) {
    print('⚠️ لا يوجد stream نشط');
    return;
  }

  // تحقق من أن هناك فيديو فعلي
  if (!stream.hasActiveVideo) {
    print('⚠️ Stream بدون فيديو فعال - تخطي الـ refresh');
    return;
  }

  print('🔄 إعادة تحديث نسيج الفيديو الأجنبي...');
  
  try {
    _remoteRenderer.srcObject = null;
    
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted && _activeViewerId != null) {
        final currentStream = _remoteStreams[_activeViewerId];
        if (currentStream != null && currentStream.hasActiveVideo) {
          setState(() {
            _remoteRenderer.srcObject = currentStream;
          });
          print('✅ تم تحديث نسيج الفيديو بنجاح');
        }
      }
    });
  } catch (e) {
    print('❌ خطأ في refresh: $e');
  }
}
```

---

## الخطوة 7: في camera_viewer_screen.dart

في دالة `_handleOffer`، استبدل `pc.onTrack`:

### ✅ الكود الجديد:
```dart
pc.onTrack = (RTCTrackEvent event) {
  print('📥 تم استقبال مسار من broadcaster: ${event.track.kind}');
  
  if (event.streams.isEmpty) {
    print('⚠️ المسار بدون streams');
    return;
  }

  _remoteStream = event.streams[0];
  
  // طبع معلومات Stream
  _remoteStream?.printInfo('RemoteStream from broadcaster');

  // فقط عرّض الـ stream إذا كان لديه فيديو
  if (_remoteStream != null && _remoteStream!.hasActiveVideo) {
    print('✅ يوجد فيديو فعال - عرض على الشاشة');
    _remoteRenderer.srcObject = _remoteStream;
    if (mounted) {
      setState(() {
        _hasRemoteVideo = true;
        _connecting = false;
        _status = "متصل";
      });
    }
  } else if (_remoteStream != null && _remoteStream!.hasAnyVideo) {
    print('⚠️ يوجد فيديو لكنه معطل - محاولة تفعيل...');
    WebRTCHelper.enableAllVideoTracks(_remoteStream);
    _remoteRenderer.srcObject = _remoteStream;
    if (mounted) {
      setState(() {
        _hasRemoteVideo = true;
        _connecting = false;
        _status = "متصل";
      });
    }
  } else {
    print('❌ لا يوجد فيديو - صوت فقط');
    if (mounted) {
      setState(() {
        _hasRemoteVideo = false;
        _connecting = false;
        _status = "متصل (صوت فقط)";
      });
    }
  }
};
```

---

## ✅ الخطوات النهائية

1. **احفظ جميع التعديلات**

2. **نظف والبناء:**
```bash
cd /path/to/project
flutter clean
flutter pub get
```

3. **شغل التطبيق:**
```bash
flutter run -v
```

4. **راقب console output:**
ابحث عن الرسائل مثل:
- ✅ "تم الحصول على الكاميرا بنجاح"
- ✅ "تم استقبال مسار: video"
- ✅ "يوجد فيديو فعال - عرض على الشاشة"

---

## 🎯 النقاط المهمة

| النقطة | الأهمية | الملاحظة |
|--------|---------|---------|
| استيراد WebRTCHelper | ⭐⭐⭐ | بدونها الكود لن يعمل |
| فحص hasActiveVideo | ⭐⭐⭐ | هذا يحل مشكلة الفيديو الأسود |
| استدعاء printInfo | ⭐⭐ | فقط للـ debugging |
| معالجة أخطاء getUserMedia | ⭐⭐ | يمنع تعطل التطبيق |
| إعادة تفعيل المسارات | ⭐ | للحالات النادرة |


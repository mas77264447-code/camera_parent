import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Helper class لتسهيل عمليات WebRTC الشائعة
/// ✅ يوفر دوال مساعدة لإدارة الـ streams والـ tracks
class WebRTCHelper {
  /// ❌ تبديل بين الكاميرا الأمامية والخلفية
  /// 
  /// المعامل [videoTrack] هو video track من الـ local stream
  /// 
  /// ```dart
  /// if (_localStream != null) {
  ///   final videoTrack = _localStream!.getVideoTracks().first;
  ///   final success = await WebRTCHelper.switchCamera(videoTrack);
  ///   if (success) print('✅ تم تبديل الكاميرا');
  /// }
  /// ```
  static Future<bool> switchCamera(MediaStreamTrack videoTrack) async {
    try {
      // استخدام الدالة المدمجة من flutter_webrtc (تم تسميتها بنفس الطريقة)
      await Helper.switchCamera(videoTrack);
      return true;
    } catch (e) {
      print('❌ فشل تبديل الكاميرا: $e');
      return false;
    }
  }

  /// ✅ التحقق من وجود video tracks في stream
  /// 
  /// يرجع `true` إذا كان هناك واحد أو أكثر من video tracks
  static bool hasVideoTrack(MediaStream? stream) {
    if (stream == null) return false;
    return stream.getVideoTracks().isNotEmpty;
  }

  /// ✅ التحقق من وجود audio tracks في stream
  /// 
  /// يرجع `true` إذا كان هناك واحد أو أكثر من audio tracks
  static bool hasAudioTrack(MediaStream? stream) {
    if (stream == null) return false;
    return stream.getAudioTracks().isNotEmpty;
  }

  /// ✅ التحقق من أن stream يحتوي على فيديو فعلي (غير معطل)
  /// 
  /// يرجع `true` فقط إذا كان الفيديو موجود و**مفعّل**
  static bool hasActiveVideo(MediaStream? stream) {
    if (stream == null) return false;
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) return false;
    // تحقق من أن واحد على الأقل من video tracks مفعّل
    return videoTracks.any((track) => track.enabled);
  }

  /// ✅ الحصول على video track الأول
  /// 
  /// يرجع `null` إذا لم يكن هناك أي video tracks
  static MediaStreamTrack? getFirstVideoTrack(MediaStream? stream) {
    if (stream == null) return null;
    final tracks = stream.getVideoTracks();
    return tracks.isNotEmpty ? tracks.first : null;
  }

  /// ✅ الحصول على audio track الأول
  /// 
  /// يرجع `null` إذا لم يكن هناك أي audio tracks
  static MediaStreamTrack? getFirstAudioTrack(MediaStream? stream) {
    if (stream == null) return null;
    final tracks = stream.getAudioTracks();
    return tracks.isNotEmpty ? tracks.first : null;
  }

  /// ✅ تعطيل جميع video tracks
  /// 
  /// هذا يوقف الكاميرا من الإرسال لكن لا يغلقها
  static void disableAllVideoTracks(MediaStream? stream) {
    if (stream == null) return;
    stream.getVideoTracks().forEach((track) {
      track.enabled = false;
    });
  }

  /// ✅ تفعيل جميع video tracks
  /// 
  /// يستأنف إرسال الكاميرا
  static void enableAllVideoTracks(MediaStream? stream) {
    if (stream == null) return;
    stream.getVideoTracks().forEach((track) {
      track.enabled = true;
    });
  }

  /// ✅ تعطيل جميع audio tracks
  /// 
  /// يوقف المايك من الإرسال
  static void disableAllAudioTracks(MediaStream? stream) {
    if (stream == null) return;
    stream.getAudioTracks().forEach((track) {
      track.enabled = false;
    });
  }

  /// ✅ تفعيل جميع audio tracks
  /// 
  /// يستأنف إرسال المايك
  static void enableAllAudioTracks(MediaStream? stream) {
    if (stream == null) return;
    stream.getAudioTracks().forEach((track) {
      track.enabled = true;
    });
  }

  /// ✅ الحصول على معلومات تفصيلية عن الـ stream (للـ debugging)
  /// 
  /// يطبع معلومات مفيدة عن جميع المسارات
  static void printStreamInfo(String streamName, MediaStream? stream) {
    if (stream == null) {
      print('📊 [$streamName] Stream = null');
      return;
    }

    print('📊 [$streamName] Stream Info:');
    
    final videoTracks = stream.getVideoTracks();
    final audioTracks = stream.getAudioTracks();
    
    print('  🎥 Video Tracks: ${videoTracks.length}');
    for (int i = 0; i < videoTracks.length; i++) {
      final track = videoTracks[i];
      print('    [$i] ID: ${track.id}');
      print('        Enabled: ${track.enabled}');
      print('        Kind: ${track.kind}');
    }
    
    print('  🔊 Audio Tracks: ${audioTracks.length}');
    for (int i = 0; i < audioTracks.length; i++) {
      final track = audioTracks[i];
      print('    [$i] ID: ${track.id}');
      print('        Enabled: ${track.enabled}');
      print('        Kind: ${track.kind}');
    }
  }

  /// ✅ إيقاف جميع المسارات في stream وتحرير الموارد
  /// 
  /// استخدم هذا قبل dispose النهائي
  static void stopAllTracks(MediaStream? stream) {
    if (stream == null) return;
    
    print('🛑 إيقاف جميع المسارات في stream...');
    
    stream.getTracks().forEach((track) {
      print('  - إيقاف ${track.kind} track: ${track.id}');
      track.stop();
    });
  }

  /// ✅ نسخ المسارات من stream إلى peer connection
  /// 
  /// هذا ينسخ جميع المسارات الفعالة فقط
  static Future<void> addTracksToConnection(
    RTCPeerConnection peerConnection,
    MediaStream sourceStream,
  ) async {
    if (peerConnection == null || sourceStream == null) {
      print('❌ Invalid peer connection or stream');
      return;
    }

    final tracks = sourceStream.getTracks();
    print('📤 إضافة ${tracks.length} مسار إلى peer connection');
    
    for (final track in tracks) {
      try {
        await peerConnection.addTrack(track, sourceStream);
        print('  ✅ تم إضافة ${track.kind} track: ${track.id}');
      } catch (e) {
        print('  ❌ فشل إضافة ${track.kind} track: $e');
      }
    }
  }

  /// ✅ التحقق من دعم الجهاز للميديا المطلوبة
  /// 
  /// يساعد في معرفة ما إذا كان الجهاز يدعم الكاميرا أو المايك
  static Future<bool> canGetUserMedia({
    bool needVideo = true,
    bool needAudio = true,
  }) async {
    try {
      final constraints = <String, dynamic>{
        if (needVideo) "video": true,
        if (needAudio) "audio": true,
      };
      
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      
      // أوقف المسارات فوراً - نحن فقط نختبر الدعم
      stream.getTracks().forEach((track) => track.stop());
      stream.dispose();
      
      return true;
    } catch (e) {
      print('⚠️ الجهاز لا يدعم: ${needVideo ? "video" : ""} ${needAudio ? "audio" : ""}');
      return false;
    }
  }
}

// ✅ امتداد (extension) مفيد على MediaStream لتسهيل الاستخدام
extension MediaStreamExtensions on MediaStream {
  /// ✅ هل هناك فيديو فعلي (مفعّل)؟
  bool get hasActiveVideo => WebRTCHelper.hasActiveVideo(this);
  
  /// ✅ هل هناك فيديو على الإطلاق؟
  bool get hasAnyVideo => WebRTCHelper.hasVideoTrack(this);
  
  /// ✅ هل هناك صوت فعلي (مفعّل)؟
  bool get hasActiveAudio {
    final audioTracks = getAudioTracks();
    if (audioTracks.isEmpty) return false;
    return audioTracks.any((track) => track.enabled);
  }
  
  /// ✅ هل هناك صوت على الإطلاق؟
  bool get hasAnyAudio => WebRTCHelper.hasAudioTrack(this);
  
  /// ✅ كتم جميع المسارات الصوتية
  void muteAudio() => WebRTCHelper.disableAllAudioTracks(this);
  
  /// ✅ تفعيل جميع المسارات الصوتية
  void unmuteAudio() => WebRTCHelper.enableAllAudioTracks(this);
  
  /// ✅ إيقاف جميع المسارات
  void stopAll() => WebRTCHelper.stopAllTracks(this);
  
  /// ✅ اطبع معلومات Stream
  void printInfo(String name) => WebRTCHelper.printStreamInfo(name, this);
}

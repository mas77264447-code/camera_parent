import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Stores WebRTC signaling state for recovery.
class WebRTCSessionManager {
  bool restoring = false;

  WebRTCSessionManager._();
  static final instance = WebRTCSessionManager._();

  Future<void> saveSession({
    required String sessionId,
    String? roomId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webrtc_session_id', sessionId);
    if (roomId != null) {
      await prefs.setString('webrtc_room_id', roomId);
    }
    await prefs.setInt(
      'webrtc_saved_at',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<Map<String, String?>> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'sessionId': prefs.getString('webrtc_session_id'),
      'roomId': prefs.getString('webrtc_room_id'),
      'offerSdp': prefs.getString('webrtc_offer_sdp'),
      'offerType': prefs.getString('webrtc_offer_type'),
      'answerSdp': prefs.getString('webrtc_answer_sdp'),
      'answerType': prefs.getString('webrtc_answer_type'),
    };
  }

  Future<void> saveOffer(RTCSessionDescription offer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webrtc_offer_sdp', offer.sdp ?? '');
    await prefs.setString('webrtc_offer_type', offer.type ?? '');
  }

  Future<void> saveAnswer(RTCSessionDescription answer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webrtc_answer_sdp', answer.sdp ?? '');
    await prefs.setString('webrtc_answer_type', answer.type ?? '');
  }

  Future<void> saveIceCandidate(RTCIceCandidate candidate) async {
    final prefs = await SharedPreferences.getInstance();
    final list =
        prefs.getStringList('webrtc_ice_candidates') ?? [];

    list.add(jsonEncode({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    }));

    await prefs.setStringList(
      'webrtc_ice_candidates',
      list,
    );
  }

  Future<List<RTCIceCandidate>> loadIceCandidates() async {
    final prefs = await SharedPreferences.getInstance();
    final list =
        prefs.getStringList('webrtc_ice_candidates') ?? [];

    return list.map((item) {
      final data = jsonDecode(item);
      return RTCIceCandidate(
        data['candidate'],
        data['sdpMid'],
        data['sdpMLineIndex'],
      );
    }).toList();
  }

  Future<void> restorePeerConnection(RTCPeerConnection pc) async {
    if (restoring) return;

    final state = await pc.getConnectionState();

    if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      restoring = true;
      try {
        await pc.restartIce();
      } finally {
        restoring = false;
      }
    }
  }
}


extension WebRTCRecoveryExtension on WebRTCSessionManager {

  Future<void> saveRecoverySnapshot() async {
    await saveSession(
      sessionId: "recovery",
      roomId: "last",
    );
  }

  Future<void> restoreIceCandidates(
      dynamic peerConnection
  ) async {
    // ICE restore hook.
    // Connect stored candidates here.
  }
}

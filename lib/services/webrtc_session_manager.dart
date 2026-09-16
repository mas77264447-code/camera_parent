import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'recovery_state.dart';

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

  Future<void> clearRecoveryState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('webrtc_session_id');
    await prefs.remove('webrtc_room_id');
    await prefs.remove('webrtc_offer_sdp');
    await prefs.remove('webrtc_offer_type');
    await prefs.remove('webrtc_answer_sdp');
    await prefs.remove('webrtc_answer_type');
    await prefs.remove('webrtc_recovery_source');
    await prefs.remove('webrtc_recovery_at');
    await prefs.remove('webrtc_saved_at');
    await clearIceCandidates();
  }

  Future<void> clearIceCandidates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('webrtc_ice_candidates');
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

  // Persist the minimal recovery marker used by the connectivity recovery flow.
  // Keep this as a real class method so all callers resolve it directly.
  Future<void> saveRecoverySnapshot({String? source, String? peerId}) async {
    final prefs = await SharedPreferences.getInstance();
    // SDP/ICE from a dead PeerConnection must not be treated as a reusable
    // connection. Keep only identity/source metadata; the next negotiation
    // creates a fresh offer/answer and fresh ICE generation.
    await prefs.remove('webrtc_offer_sdp');
    await prefs.remove('webrtc_offer_type');
    await prefs.remove('webrtc_answer_sdp');
    await prefs.remove('webrtc_answer_type');
    await clearIceCandidates();
    await saveSession(
      sessionId: peerId ?? 'recovery',
      roomId: 'last',
    );
    if (source != null) {
      await prefs.setString('webrtc_recovery_source', source);
    }
    await prefs.setInt(
      'webrtc_recovery_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    RecoveryState.instance.setPhase(
      RecoveryPhase.networkLost,
      detail: source == null ? 'network loss' : 'network loss: $source',
    );
  }

  Future<void> restoreIceCandidates(dynamic peerConnection) async {
    // ICE restore hook.
    // Connect stored candidates here.
  }
}

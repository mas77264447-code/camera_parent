import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_service.dart';
import 'screen_capture_service.dart';
import 'webrtc_session_manager.dart';
import 'connection_state_manager.dart';
import 'recovery_queue.dart';
import 'recovery_state.dart';


class StreamManager {

  StreamManager._();

  static final StreamManager instance =
      StreamManager._();


  MediaStream? localStream;

  WebSocket? ws;


  final Map<String, RTCPeerConnection>
      peerConnections = {};

  final Map<String, Future<void> Function()> _recoveryHandlers = {};
  bool _reconnectInFlight = false;
  int _reconnectAttempt = 0;
  int _socketGeneration = 0;

  void registerPeerConnection({
    required String viewerId,
    required RTCPeerConnection peerConnection,
    required Future<void> Function() recover,
  }) {
    peerConnections[viewerId] = peerConnection;
    _recoveryHandlers[viewerId] = recover;
  }

  void unregisterPeerConnection(String viewerId, {RTCPeerConnection? peerConnection}) {
    if (peerConnection == null || peerConnections[viewerId] == peerConnection) {
      peerConnections.remove(viewerId);
      _recoveryHandlers.remove(viewerId);
    }
  }


  List<Map<String, dynamic>> iceServers = [
    {
      "urls": "stun:stun.l.google.com:19302"
    }
  ];


  bool running = false;

  final WebRTCSessionManager sessionManager = WebRTCSessionManager.instance;

  bool hasActivePeerConnection() {
    return peerConnections.values.any((pc) {
      return pc.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
    });
  }

  bool hasRecoverablePeerConnection() {
    return peerConnections.values.any((pc) {
      final state = pc.connectionState;
      return state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed;
    });
  }

  Future<void> recoverWebRTC() async {
    final handlers = List<Future<void> Function()>.from(_recoveryHandlers.values);
    if (handlers.isNotEmpty) {
      for (final recover in handlers) {
        try {
          await recover();
        } catch (e) {
          debugPrint('[Recovery] handler failed: $e');
        }
      }
      return;
    }

    // Fallback for legacy callers: restart ICE only for connections that
    // are still alive. A CLOSED PeerConnection must be rebuilt by its owner.
    for (final pc in List<RTCPeerConnection>.from(peerConnections.values)) {
      try {
        await sessionManager.restorePeerConnection(pc);
      } catch (_) {}
    }
  }

  Future<void> closeDeadConnections() async {
    final dead = <String>[];
    peerConnections.forEach((id, pc) {
      if (pc.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        dead.add(id);
      }
    });
    for (final id in dead) {
      await peerConnections[id]?.close();
      peerConnections.remove(id);
    }
  }


  String? deviceToken;


  String server =
      CameraService.server;



  Future<void> initialize({
    required String token,
  }) async {

    deviceToken = token;

    await loadIceServers();

  }



  Future<void> loadIceServers() async {

    try {

      iceServers =
          await CameraService.fetchIceServers();

    } catch (_) {}

  }



  Future<void> startCamera() async {

    await stopMedia();


    localStream =
        await CameraService.getUserMedia(
      audio: true,
      video: true,
      videoConstraints: {

        "mandatory": {

          "minWidth": 640,
          "minHeight": 480,
          "minFrameRate": 30,

        },

        "optional": []

      },
    );


    running = true;

  }



  Future<void> startScreen() async {

    await stopMedia();


    localStream =
        await ScreenCaptureService
            .startScreenCapture();


    running = true;

  }



  Future<void> connectWebSocket() async {
    if (deviceToken == null) {
      throw Exception('device token missing');
    }
    if (isWebSocketConnected()) return;

    final generation = ++_socketGeneration;
    final wsUrl = server.replaceFirst(RegExp(r'^http'), 'ws');
    ConnectionStateManager.instance.update(
      ConnectionStatus.connecting,
      detail: 'signaling',
    );

    final socket = await WebSocket.connect(
      '$wsUrl/signal',
    ).timeout(const Duration(seconds: 10));

    if (generation != _socketGeneration || !running) {
      await socket.close();
      return;
    }

    final old = ws;
    ws = socket;
    try { await old?.close(); } catch (_) {}

    _reconnectAttempt = 0;
    socket.add(jsonEncode({
      'type': 'register',
      'role': 'broadcaster',
      'deviceToken': deviceToken,
    }));

    ConnectionStateManager.instance.update(
      ConnectionStatus.connected,
      detail: 'signaling',
    );

    socket.listen(
      handleMessage,
      onDone: () {
        if (generation != _socketGeneration || !identical(ws, socket)) return;
        ws = null;
        ConnectionStateManager.instance.update(
          ConnectionStatus.networkLost,
          detail: 'signaling closed',
        );
        reconnect();
      },
      onError: (_) {
        if (generation != _socketGeneration || !identical(ws, socket)) return;
        ws = null;
        ConnectionStateManager.instance.update(
          ConnectionStatus.networkLost,
          detail: 'signaling error',
        );
        reconnect();
      },
      cancelOnError: false,
    );
  }



  void handleMessage(dynamic message) {


    try {


      final data =
          jsonDecode(message);


      debugPrint(
        "STREAM EVENT: $data"
      );


      // سيتم نقل منطق:
      // offer
      // answer
      // ice
      // viewer
      // هنا من camera_stream_screen


    } catch(e){

      debugPrint(
        "Stream error $e"
      );

    }

  }



  bool isWebSocketConnected() {
    return ws != null && ws!.readyState == WebSocket.open;
  }


  Future<void> reconnect() async {
    if (!running || _reconnectInFlight || isWebSocketConnected()) return;
    _reconnectInFlight = true;
    try {
      _reconnectAttempt = (_reconnectAttempt + 1).clamp(1, 8);
      final delay = Duration(
        milliseconds: (500 * (1 << (_reconnectAttempt - 1))).clamp(500, 15000),
      );
      await Future.delayed(delay);
      await reconnectSignaling();
    } catch (_) {
      // Next network/heartbeat event can retry the same serialized pipeline.
    } finally {
      _reconnectInFlight = false;
    }
  }




  /// Fully rebuilds a PeerConnection after a fatal failure.
  /// This closes stale connections and prepares a new signaling cycle.
  Future<void> rebuildPeerConnection(String id) async {
    final recover = _recoveryHandlers[id];
    if (recover != null) {
      await recover();
      return;
    }

    final old = peerConnections[id];
    try {
      await old?.close();
    } catch (_) {}

    peerConnections.remove(id);
    _recoveryHandlers.remove(id);
    await closeDeadConnections();
  }


  Future<void> rebuildAllPeerConnections() async {
    final ids = List<String>.from(peerConnections.keys);

    for (final id in ids) {
      await rebuildPeerConnection(id);
    }
  }



  /// Network recovery integration
  Future<void> pauseForNetworkLoss() async {
    RecoveryState.instance.setPhase(RecoveryPhase.networkLost, detail: 'network');
    ConnectionStateManager.instance.update(ConnectionStatus.networkLost, detail: 'network');
    await sessionManager.saveRecoverySnapshot(source: await getSavedSource());
  }

  Future<void> reconnectSignaling() async {
    if (isWebSocketConnected()) return;
    await connectWebSocket();
  }

  Future<void> restoreSessionAndIce() async {
    final session = await sessionManager.loadSession();

    if (session.isNotEmpty) {
      debugPrint("Restoring WebRTC session: $session");
    }
  }

  Future<void> verifyStream() async {
    final healthy = hasActivePeerConnection();
    debugPrint("Stream health: $healthy");
    ConnectionStateManager.instance.update(
      healthy ? ConnectionStatus.connected : ConnectionStatus.failed,
      detail: healthy ? 'webrtc connected' : 'peer connection not connected',
    );
  }

  /// Single recovery entry point used by network, heartbeat and UI recovery.
  /// Keeping these steps in one method prevents multiple subsystems from
  /// opening competing signaling/ICE recovery cycles.
  Future<void> recoverSession() async {
    if (!running) return;
    RecoveryState.instance.startedAttempt();
    ConnectionStateManager.instance.update(
      ConnectionStatus.reconnecting,
      detail: 'recovery',
    );
    await reconnect();
    await restoreSessionAndIce();
    ConnectionStateManager.instance.update(
      ConnectionStatus.negotiating,
      detail: 'webrtc',
    );
    await recoverWebRTC();
    await verifyStream();
    if (hasActivePeerConnection()) {
      RecoveryState.instance.markSuccess(detail: 'WebRTC connected');
    } else {
      RecoveryState.instance.markFailure('WebRTC did not reconnect');
    }
  }

  Future<void> stopMedia() async {


    if(localStream != null){


      for(final track
          in localStream!.getTracks()){

        await track.stop();

      }


      await localStream!.dispose();


      localStream=null;

    }

  }



  Future<void> stop() async {


    running=false;


    await stopMedia();


    await ws?.close();


    ws=null;


    for(final pc
        in peerConnections.values){

      await pc.close();

    }


    peerConnections.clear();

  }



  Future<void> saveSource(
      String source
  ) async {


    final prefs =
        await SharedPreferences.getInstance();


    await prefs.setString(
      "last_stream_source",
      source,
    );

  }



  Future<String> getSavedSource()
  async {


    final prefs =
        await SharedPreferences.getInstance();


    return prefs.getString(
      "last_stream_source"
    ) ?? "camera";

  }

}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_service.dart';
import 'screen_capture_service.dart';
import 'webrtc_session_manager.dart';


class StreamManager {

  StreamManager._();

  static final StreamManager instance =
      StreamManager._();


  MediaStream? localStream;

  WebSocket? ws;


  final Map<String, RTCPeerConnection>
      peerConnections = {};

  final Map<String, Future<void> Function()> _recoveryHandlers = {};

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

    if(deviceToken == null) {
      throw Exception(
        "device token missing"
      );
    }


    final wsUrl =
        server.replaceFirst(
          RegExp(r'^http'),
          'ws',
        );


    ws =
      await WebSocket.connect(
        '$wsUrl/signal'
      );


    ws!.add(jsonEncode({

      "type":"register",

      "role":"broadcaster",

      "deviceToken":deviceToken,

    }));



    ws!.listen(

      handleMessage,

      onDone: () {

        reconnect();

      },

      onError: (_) {

        reconnect();

      },

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


    if(!running) return;


    await Future.delayed(
      const Duration(seconds:3)
    );


    try{

      await connectWebSocket();

    }catch(_){}


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
    // Keep current session data before reconnect.
    await sessionManager.saveRecoverySnapshot();
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
    debugPrint(
      "Stream health: ${hasActivePeerConnection()}"
    );
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
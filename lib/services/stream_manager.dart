import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_service.dart';
import 'screen_capture_service.dart';


class StreamManager {

  StreamManager._();

  static final StreamManager instance =
      StreamManager._();


  MediaStream? localStream;

  WebSocket? ws;


  final Map<String, RTCPeerConnection>
      peerConnections = {};


  List<Map<String, dynamic>> iceServers = [
    {
      "urls": "stun:stun.l.google.com:19302"
    }
  ];


  bool running = false;


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



  Future<void> reconnect() async {


    if(!running) return;


    await Future.delayed(
      const Duration(seconds:3)
    );


    try{

      await connectWebSocket();

    }catch(_){}


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
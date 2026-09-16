import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/native_bridge.dart';
import 'services/connectivity_method_channel.dart';
import 'services/stream_manager.dart';
import 'services/webrtc_session_manager.dart';
import 'services/recovery_queue.dart';
import 'services/secure_store.dart';

import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/camera_stream_screen.dart';

const bool isChildBuild =
    bool.fromEnvironment('IS_CHILD_BUILD', defaultValue: false);


void main() {

  WidgetsFlutterBinding.ensureInitialized();

  NativeBridge.initialize();

  // Receive native Android connectivity events through the persistent
  // Flutter engine. The handler delegates to the existing WebRTC recovery
  // manager; it does not create a second signaling connection.
  ConnectivityMethodChannel.initialize(
    onNetworkChanged: (online) async {
      if (!online) {
        await StreamManager.instance.pauseForNetworkLoss();
        return;
      }

      await RecoveryQueue.instance.enqueue(() async {
        await StreamManager.instance.recoverSession();
      }, key: 'stream-recovery');
    },
  );



  runApp(const CameraParentApp());
}



class CameraParentApp extends StatelessWidget {

  const CameraParentApp({super.key});


  @override
  Widget build(BuildContext context) {

    return MaterialApp(

      title: isChildBuild
          ? "Camera Child"
          : "Camera Parent",

      debugShowCheckedModeBanner: false,

      theme:
          ThemeData(primarySwatch: Colors.blue),

      home: isChildBuild
          ? const _ChildEntry()
          : const HomeScreen(),

    );

  }

}



class _ChildEntry extends StatefulWidget {

  const _ChildEntry();


  @override
  State<_ChildEntry> createState() =>
      _ChildEntryState();

}



class _ChildEntryState extends State<_ChildEntry> {


  bool _loading = true;

  Map<String,String?>? _stored;



  @override
  void initState() {

    super.initState();

    _load();

  }



  Future<void> _load() async {


    final prefs =
        await SharedPreferences.getInstance();


    final paired =
        prefs.getBool('is_paired') ?? false;



    if (paired) {

      final deviceToken =
          await SecureStore.read('device_token');

      if (!mounted) return;

      setState(() {

        _stored = {

          'device_token': deviceToken,

          'session_id':
              prefs.getString('session_id'),

          'device_name':
              prefs.getString('device_name'),

        };

        _loading = false;

      });


    } else {


      setState(() {

        _loading = false;

      });


    }

  }





  @override
  Widget build(BuildContext context) {


    if (_loading) {

      return const Scaffold(

        body:
          Center(

            child:
              CircularProgressIndicator(),

          ),

      );

    }



    if (_stored != null &&
        _stored!['device_token'] != null) {


      return CameraStreamScreen(

        sessionId:
            _stored!['session_id']!,


        cameraName:
            _stored!['device_name'] ??
            'جهاز الطفل',


        deviceToken:
            _stored!['device_token']!,

      );


    }



    return const PairingScreen();

  }

}
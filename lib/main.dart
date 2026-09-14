import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/native_bridge.dart';
import 'services/agent_service.dart';

import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/camera_stream_screen.dart';

const bool isChildBuild =
    bool.fromEnvironment('IS_CHILD_BUILD', defaultValue: false);


void main() {

  WidgetsFlutterBinding.ensureInitialized();

  NativeBridge.initialize();


  const MethodChannel serviceChannel =
      MethodChannel('camera_parent/service');


  serviceChannel.setMethodCallHandler(
    (call) async {

      switch (call.method) {

        case 'startAgent':
          AgentService.instance.start();
          break;


        case 'stopAgent':
          AgentService.instance.stop();
          break;

      }

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


      setState(() {

        _stored = {

          'device_token':
              prefs.getString('device_token'),

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
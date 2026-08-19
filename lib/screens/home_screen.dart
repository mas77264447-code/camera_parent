import 'package:flutter/material.dart';
import '../services/camera_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {

  String? link;
  bool loading = false;

  Future<void> createSession() async {
    setState(() {
      loading = true;
    });

    try {
      final result = await CameraService.createCameraSession();

      setState(() {
        link = result;
      });

    } catch (e) {
      setState(() {
        link = "Error: $e";
      });
    }

    setState(() {
      loading = false;
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Camera Parent"),
      ),

      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [

              ElevatedButton(
                onPressed: loading ? null : createSession,
                child: Text(
                  loading
                      ? "Creating..."
                      : "Create Camera Request",
                ),
              ),

              const SizedBox(height: 30),

              if (link != null)
                SelectableText(
                  link!,
                  textAlign: TextAlign.center,
                ),

            ],
          ),
        ),
      ),
    );
  }
}

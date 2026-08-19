import 'package:flutter/material.dart';
import '../services/camera_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {

  String? childUrl;
  bool loading = false;

  Future<void> createCameraLink() async {

    setState(() {
      loading = true;
    });

    final url = await CameraService.createCameraSession();

    setState(() {
      loading = false;
      childUrl = url;
    });
  }


  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(
        title: const Text("Camera Parent"),
      ),

      body: Padding(
        padding: const EdgeInsets.all(20),

        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,

          children: [

            ElevatedButton(
              onPressed: loading ? null : createCameraLink,

              child: loading
                  ? const CircularProgressIndicator()
                  : const Text(
                      "طلب فتح الكاميرا",
                      style: TextStyle(fontSize: 18),
                    ),
            ),


            const SizedBox(height: 30),


            if (childUrl != null)

              SelectableText(
                "رابط الطفل:\n\n$childUrl",
                style: const TextStyle(
                  fontSize: 16,
                ),
              ),

          ],
        ),
      ),
    );
  }
}

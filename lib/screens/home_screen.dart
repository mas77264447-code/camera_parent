import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/camera_service.dart';
import 'camera_stream_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {

  bool loading = false;
  String? childUrl;
  String? sessionId;
  String? errorMessage;


  Future<void> createSession() async {

    setState(() {
      loading = true;
      errorMessage = null;
    });

    try {

      final result = await CameraService.createCameraSession();

      if (!mounted) return;

      setState(() {

        childUrl = result?["child_url"];
        sessionId = result?["session_id"];
        loading = false;

      });

    } catch (e) {

      if (!mounted) return;

      setState(() {

        loading = false;
        errorMessage = e.toString();

      });

    }

  }


  Future<void> copyUrl() async {

    if (childUrl == null) return;

    await Clipboard.setData(
      ClipboardData(
        text: childUrl!,
      ),
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'تم نسخ الرابط',
        ),
      ),
    );

  }

  void startStreaming() {
    if (sessionId == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CameraStreamScreen(sessionId: sessionId!),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(
        title: const Text(
          "Camera Parent",
        ),
        centerTitle: true,
      ),

      body: Padding(

        padding: const EdgeInsets.all(20),

        child: Column(

          mainAxisAlignment: MainAxisAlignment.center,

          crossAxisAlignment: CrossAxisAlignment.stretch,

          children: [

            const Icon(
              Icons.camera_alt,
              size: 80,
              color: Colors.deepPurple,
            ),

            const SizedBox(height: 20),

            ElevatedButton.icon(

              onPressed: loading ? null : createSession,

              icon: loading

                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )

                  : const Icon(Icons.add_link),

              label: Text(
                loading
                    ? "جاري إنشاء الرابط..."
                    : "إنشاء رابط للطفل",
              ),

            ),

            const SizedBox(height: 30),

            if (errorMessage != null)

              Text(
                errorMessage!,
                style: const TextStyle(
                  color: Colors.red,
                ),
              ),


            if (childUrl != null) ...[

              SelectableText(

                "رابط الطفل:\n\n$childUrl",

                style: const TextStyle(
                  fontSize: 16,
                ),

              ),

              const SizedBox(height: 20),


              ElevatedButton.icon(

                onPressed: copyUrl,

                icon: const Icon(
                  Icons.copy,
                ),

                label: const Text(
                  "نسخ الرابط",
                ),

              ),

              const SizedBox(height: 12),

              ElevatedButton.icon(

                onPressed: startStreaming,

                icon: const Icon(
                  Icons.videocam,
                ),

                label: const Text(
                  "ابدأ البث",
                ),

              ),

            ],

          ],

        ),

      ),

    );

  }

}

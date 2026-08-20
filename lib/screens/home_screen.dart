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

  final TextEditingController nameController = TextEditingController();

  bool loading = false;
  String? childUrl;
  String? sessionId;
  String? dashboardUrl;
  String? errorMessage;


  Future<void> createSession() async {

    final name = nameController.text.trim().isEmpty
        ? "كاميرا بدون اسم"
        : nameController.text.trim();

    setState(() {
      loading = true;
      errorMessage = null;
    });

    try {

      final result = await CameraService.createCameraSession(name);

      if (!mounted) return;

      setState(() {

        childUrl = result?["child_url"];
        sessionId = result?["session_id"];
        dashboardUrl = result?["dashboard_url"];
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


  Future<void> copyText(String text, String message) async {

    await Clipboard.setData(
      ClipboardData(
        text: text,
      ),
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
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

      body: SingleChildScrollView(

        padding: const EdgeInsets.all(20),

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.stretch,

          children: [

            const Icon(
              Icons.camera_alt,
              size: 80,
              color: Colors.deepPurple,
            ),

            const SizedBox(height: 20),

            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: "اسم الكاميرا (مثلاً: المحل، غرفة النوم)",
                border: OutlineInputBorder(),
              ),
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

              const Divider(),

              const SizedBox(height: 10),

              const Text(
                "رابط مشاهدة هذه الكاميرا بس:",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 8),

              SelectableText(childUrl!),

              const SizedBox(height: 10),

              ElevatedButton.icon(
                onPressed: () => copyText(childUrl!, "تم نسخ رابط الكاميرا"),
                icon: const Icon(Icons.copy),
                label: const Text("نسخ رابط الكاميرا"),
              ),

              const SizedBox(height: 24),

              if (dashboardUrl != null) ...[

                const Text(
                  "لوحة تحكم كل الكاميرات (افتحها مرة واحدة وهتشوف كل الكاميرات فيها):",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 8),

                SelectableText(dashboardUrl!),

                const SizedBox(height: 10),

                ElevatedButton.icon(
                  onPressed: () => copyText(dashboardUrl!, "تم نسخ رابط اللوحة"),
                  icon: const Icon(Icons.dashboard),
                  label: const Text("نسخ رابط اللوحة"),
                ),

              ],

              const SizedBox(height: 24),

              ElevatedButton.icon(

                onPressed: startStreaming,

                icon: const Icon(
                  Icons.videocam,
                ),

                label: const Text(
                  "ابدأ البث من هذا الموبايل",
                ),

              ),

            ],

          ],

        ),

      ),

    );

  }

}

import 'package:flutter/material.dart';
import 'camera_viewer_screen.dart';

class DeviceConnectionScreen extends StatelessWidget {
  final String sessionId;
  final String name;
  final String adminToken;

  const DeviceConnectionScreen({
    super.key,
    required this.sessionId,
    required this.name,
    required this.adminToken,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [

            const SizedBox(height: 40),

            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.camera_alt,
                  size: 40,
                ),
                title: const Text(
                  "الكاميرا",
                  style: TextStyle(fontSize: 20),
                ),
                subtitle: const Text(
                  "مشاهدة كاميرا جهاز الطفل",
                ),
                trailing: const Icon(Icons.arrow_forward_ios),

                onTap: () {

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          CameraViewerScreen(
                            sessionId: sessionId,
                            name: name,
                            adminToken: adminToken,
                          ),
                    ),
                  );

                },
              ),
            ),

            const SizedBox(height: 20),

            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.screen_share,
                  size: 40,
                ),
                title: const Text(
                  "مشاركة الشاشة",
                  style: TextStyle(fontSize: 20),
                ),
                subtitle: const Text(
                  "عرض شاشة جهاز الطفل",
                ),
                trailing: const Icon(Icons.arrow_forward_ios),

                onTap: () {

                  ScaffoldMessenger.of(context)
                      .showSnackBar(
                    const SnackBar(
                      content: Text(
                        "سيتم ربط مشاركة الشاشة مع WebRTC",
                      ),
                    ),
                  );

                },
              ),
            ),

          ],
        ),
      ),
    );
  }
}

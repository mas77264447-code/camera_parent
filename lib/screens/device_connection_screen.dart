import 'package:flutter/material.dart';
import 'camera_viewer_screen.dart';
import 'device_files_screen.dart';

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

            // بطاقة واحدة بس - عند الدخول عليها هتسألك مباشرة "الكاميرا
            // ولا الشاشة؟" (شوف CameraViewerScreen._chooseRequestedSource)
            // فمفيش داعي لبطاقة "مشاركة الشاشة" منفصلة كانت أصلاً مجرد
            // Placeholder مش متوصل بأي بث حقيقي.
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.camera_alt,
                  size: 40,
                ),
                title: const Text(
                  "مشاهدة الجهاز",
                  style: TextStyle(fontSize: 20),
                ),
                subtitle: const Text(
                  "شاهد كاميرا أو شاشة جهاز الطفل",
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

            const SizedBox(height: 12),

            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.folder,
                  size: 40,
                ),
                title: const Text(
                  "ملفات الجهاز",
                  style: TextStyle(fontSize: 20),
                ),
                subtitle: const Text(
                  "استعراض الصور والفيديو والملفات بعد موافقة صاحب الجهاز",
                ),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DeviceFilesScreen(
                        sessionId: sessionId,
                        name: name,
                        adminToken: adminToken,
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

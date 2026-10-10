import 'package:flutter/material.dart';
import 'camera_viewer_screen.dart';
import 'device_files_screen.dart';
import 'web_link_screen.dart';

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
      appBar: AppBar(title: Text(name)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 20),
            Card(
              child: ListTile(
                leading: const Icon(Icons.camera_alt, size: 40),
                title: const Text("مشاهدة الجهاز",
                    style: TextStyle(fontSize: 20)),
                subtitle: const Text("شاهد كاميرا جهاز الطفل مباشرة"),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CameraViewerScreen(
                        sessionId: sessionId,
                        name: name,
                        adminToken: adminToken,
                        initialSource: "camera",
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.screen_share,
                    size: 40, color: Colors.deepPurple),
                title: const Text("مشاهدة الشاشة",
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                subtitle: const Text("شاهد شاشة جهاز الطفل في الوقت الفعلي"),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CameraViewerScreen(
                        sessionId: sessionId,
                        name: name,
                        adminToken: adminToken,
                        initialSource: "screen",
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder, size: 40),
                title: const Text("ملفات الجهاز",
                    style: TextStyle(fontSize: 20)),
                subtitle: const Text(
                    "استعراض الصور والفيديو والملفات بعد موافقة صاحب الجهاز"),
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
            const SizedBox(height: 12),
            Card(
              color: Colors.blue.shade50,
              child: ListTile(
                leading: const Icon(Icons.link,
                    size: 40, color: Colors.blue),
                title: const Text("إضافة عبر رابط ⭐",
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                subtitle: const Text(
                    "شارك رابطاً يفتحه الطفل في المتصفح — بدون تثبيت"),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WebLinkScreen(
                        adminToken: adminToken,
                        deviceName: name,
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

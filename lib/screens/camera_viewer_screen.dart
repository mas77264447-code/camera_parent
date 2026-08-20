import 'dart:async';
import 'package:flutter/material.dart';
import '../services/camera_service.dart';

class CameraViewerScreen extends StatefulWidget {
  final String sessionId;
  final String name;

  const CameraViewerScreen({
    super.key,
    required this.sessionId,
    required this.name,
  });

  @override
  State<CameraViewerScreen> createState() => _CameraViewerScreenState();
}

class _CameraViewerScreenState extends State<CameraViewerScreen> {
  Timer? _timer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (mounted) {
        setState(() {
          _tick++;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url =
        "${CameraService.server}/camera/frame?session=${widget.sessionId}&t=$_tick";

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.name),
        centerTitle: true,
      ),
      body: Center(
        child: Image.network(
          url,
          key: ValueKey(_tick),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => const Text(
            "مفيش بث حالياً من الكاميرا دي",
            style: TextStyle(color: Colors.white70),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const CircularProgressIndicator();
          },
        ),
      ),
    );
  }
}

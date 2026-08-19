import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const CameraParentApp());
}

class CameraParentApp extends StatelessWidget {
  const CameraParentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Parent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const HomeScreen(),
    );
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class ReceivedFilesScreen extends StatefulWidget {
  const ReceivedFilesScreen({super.key});

  @override
  State<ReceivedFilesScreen> createState() => _ReceivedFilesScreenState();
}

class _ReceivedFilesScreenState extends State<ReceivedFilesScreen> {
  List<FileSystemEntity> _files = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await getApplicationDocumentsDirectory();
    final entries = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.split(Platform.pathSeparator).last.startsWith('received_'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (mounted) setState(() => _files = entries);
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // الملف قد يكون حُذف بالفعل أو لم يعد متاحًا.
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الملفات المستلمة')),
      body: _files.isEmpty
          ? const Center(child: Text('لا توجد ملفات مستلمة'))
          : ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index] as File;
                final name = file.path.split(Platform.pathSeparator).last.replaceFirst(RegExp(r'^received_\d+_'), '');
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(name),
                  subtitle: Text('${file.lengthSync()} بايت'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(file),
                  ),
                );
              },
            ),
    );
  }
}

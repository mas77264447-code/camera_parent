import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/camera_service.dart';
import '../services/crypto_service.dart';

class DeviceFilesScreen extends StatefulWidget {
  final String sessionId;
  final String name;
  final String adminToken;

  const DeviceFilesScreen({
    super.key,
    required this.sessionId,
    required this.name,
    required this.adminToken,
  });

  @override
  State<DeviceFilesScreen> createState() => _DeviceFilesScreenState();
}

class _DeviceFilesScreenState extends State<DeviceFilesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  WebSocket? _ws;
  bool _approved = false;
  bool _ready = false;
  String _status = "جاري الاتصال...";
  bool _permissionMissingOnChild = false;

  List<Map<String, dynamic>> _galleryItems = [];
  List<Map<String, dynamic>> _fileItems = [];
  String? _currentPath;
  String? _parentPath;
  bool _loading = false;
  Timer? _loadTimeout;
  Timer? _pingTimer; // ✅ إصلاح: ping للحفاظ على الاتصال

  final Map<String, _TransferState> _transfers = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
    _connect();
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    _pingTimer?.cancel(); // ✅ إصلاح
    _tabs.dispose();
    try {
      if (_ws?.readyState == WebSocket.open) {
        _ws!.add(jsonEncode({'type': 'leave-viewer'}));
      }
      _ws?.close();
    } catch (_) {}
    for (final s in _transfers.values) {
      try { s.sink?.close(); } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      final wsUrl = CameraService.server
              .replaceFirst('https://', 'wss://')
              .replaceFirst('http://', 'ws://') +
          '/signal';

      _ws = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 10));

      // ✅ إصلاح: listen قبل add
      _ws!.listen(
        _handleMessage,
        onError: (e) {
          debugPrint('[Files] ws error: $e');
          if (mounted) setState(() => _status = 'خطأ في الاتصال');
        },
        onDone: () {
          _pingTimer?.cancel();
          if (mounted) setState(() => _status = 'انقطع الاتصال');
        },
        cancelOnError: true,
      );

      _ws!.add(jsonEncode({
        'type': 'register',
        'role': 'viewer',
        'session': widget.sessionId,
        'adminToken': widget.adminToken,
        'name': 'الوالد',
        'requestedSource': 'files',
      }));

      // ✅ إصلاح: ping كل 15 ثانية
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (_ws?.readyState == WebSocket.open) {
          try {
            _ws!.add(jsonEncode({
              'type': 'ping',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }));
          } catch (_) {}
        }
      });

      setState(() => _status = 'جاري التحقق من الجهاز...');
    } catch (e) {
      debugPrint('[Files] connect error: $e');
      if (mounted) setState(() => _status = 'فشل الاتصال: $e');
    }
  }

  void _handleMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String);
      final type = msg['type'] as String?;
      debugPrint('[Files] ← $type');

      switch (type) {
        case 'viewer-approved':
          setState(() {
            _approved = true;
            _ready = true;
            _status = 'متصل — اختر صور / فيديو / ملفات';
          });
          break;

        case 'await-approval':
          setState(() => _status = 'في انتظار موافقة جهاز الطفل...');
          break;

        case 'join-rejected':
          setState(() {
            _status = 'جهاز الطفل رفض الاتصال';
            _ready = true;
          });
          break;

        case 'auth-failed':
          setState(() {
            _status = 'فشل التحقق من الجلسة';
            _ready = true;
          });
          break;

        case 'broadcaster-left':
          setState(() {
            _approved = false;
            _status = 'انقطع جهاز الطفل — في انتظار عودته...';
          });
          break;

        case 'file-browser-list-response':
          _loadTimeout?.cancel();
          final ok = msg['ok'] == true;
          final items = (msg['items'] as List?)
                  ?.map((e) => Map<String, dynamic>.from(e as Map))
                  .toList() ??
              [];
          final path = msg['path']?.toString();
          final errorMsg = msg['error']?.toString() ?? '';

          setState(() {
            _loading = false;
            if (!ok) {
              _status = 'خطأ: ${errorMsg.isEmpty ? 'unknown' : errorMsg}';
              if (errorMsg.contains('الصلاحيات غير ممنوحة') ||
                  errorMsg.contains('صلاحية') ||
                  errorMsg.contains('PERMISSION')) {
                _permissionMissingOnChild = true;
              }
              return;
            }
            _permissionMissingOnChild = false;

            if (path != null && path.startsWith('gallery://')) {
              _galleryItems = items;
              _status = '${items.length} عنصر';
            } else {
              _fileItems = items;
              _currentPath = path;
              _parentPath = msg['parent']?.toString();
              _status = errorMsg.isNotEmpty
                  ? 'تنبيه: $errorMsg'
                  : '${items.length} عنصر';
            }
          });
          break;

        case 'file-transfer-start':
          final requestId = msg['requestId']?.toString();
          if (requestId == null) return;
          final state = _transfers[requestId];
          if (state == null) return;
          setState(() {
            state.size = (msg['size'] as num?)?.toInt() ?? 0;
          });
          break;

        case 'file-transfer-chunk':
          final requestId = msg['requestId']?.toString();
          final data = msg['data'] as String?;
          if (requestId == null || data == null) return;
          final state = _transfers[requestId];
          if (state == null || state.canceled || state.paused) return;
          try {
            final encrypted = base64Decode(data);

            Uint8List decrypted;
            if (CryptoService.instance.isInitialized) {
              try {
                decrypted = CryptoService.instance.decrypt(encrypted);
              } catch (e) {
                debugPrint('[Files] decrypt failed: $e');
                return;
              }
            } else {
              decrypted = encrypted;
            }

            if (state.mode == TransferMode.preview) {
              state.chunks.add(decrypted);
            } else {
              state.sink?.add(decrypted);
            }
            state.received += decrypted.length;
            setState(() {});
          } catch (e) {
            debugPrint('[Files] chunk error: $e');
          }
          break;

        case 'file-transfer-end':
          final requestId = msg['requestId']?.toString();
          if (requestId == null) return;
          _finishTransfer(requestId, msg);
          break;
      }
    } catch (e) {
      debugPrint('[Files] msg error: $e');
    }
  }

  Future<void> _showChildPermissionHelp() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مطلوب تفعيل على جهاز الطفل'),
        content: const Text(
          'جهاز الطفل لا يملك صلاحية "الوصول لجميع الملفات" بعد.\n\n'
          'على جهاز الطفل، افتح:\n'
          '1. تطبيق الطفل\n'
          '2. الإعدادات → التطبيقات → التطبيق\n'
          '3. الإذونات → الملفات والوسائط\n'
          '4. فعّل "الوصول لجميع الملفات"\n\n'
          'ثم ارجع لهنا وحاول مرة أخرى.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  void _preview(String uri, String name, String mime) {
    if (_ws?.readyState != WebSocket.open || !_approved) return;
    if (!CryptoService.instance.isInitialized) {
      setState(() => _status = 'E2E غير مُهيَّأ');
      return;
    }
    final requestId = _uid();
    setState(() {
      _transfers[requestId] = _TransferState(
        name: name,
        uri: uri,
        mode: TransferMode.preview,
        mime: mime,
      );
    });
    _ws!.add(jsonEncode({
      'type': 'file-browser-download',
      'requestId': requestId,
      'uri': uri,
      'name': name,
      'offset': 0,
    }));
  }

  Future<void> _startDownload(String uri, String name, String mime) async {
    if (_ws?.readyState != WebSocket.open || !_approved) return;
    if (!CryptoService.instance.isInitialized) {
      setState(() => _status = 'E2E غير مُهيَّأ');
      return;
    }
    final dest = await _askSaveLocation(name);
    if (dest == null) return;

    final requestId = _uid();
    final safeName = name.replaceAll(RegExp(r'[^\w\.\-]'), '_');
    final tempFile = File('${dest.path}/$safeName.part');
    final sink = tempFile.openWrite();

    setState(() {
      _transfers[requestId] = _TransferState(
        name: name,
        uri: uri,
        mode: TransferMode.download,
        mime: mime,
        saveDir: dest,
        tempFile: tempFile,
        sink: sink,
      );
    });

    _ws!.add(jsonEncode({
      'type': 'file-browser-download',
      'requestId': requestId,
      'uri': uri,
      'name': name,
      'offset': 0,
    }));
  }

  Future<void> _pauseTransfer(String requestId) async {
    final state = _transfers[requestId];
    if (state == null || state.paused || state.canceled) return;
    if (state.mode != TransferMode.download) return;

    _ws!.add(jsonEncode({
      'type': 'file-transfer-cancel',
      'requestId': requestId,
    }));

    try {
      await state.sink?.flush();
      await state.sink?.close();
    } catch (_) {}
    state.sink = null;
    state.paused = true;

    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم إيقاف التحميل مؤقتاً'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _resumeTransfer(String oldRequestId) async {
    final state = _transfers[oldRequestId];
    if (state == null || !state.paused || state.canceled) return;

    final newRequestId = _uid();
    try {
      state.sink = state.tempFile!.openWrite(mode: FileMode.append);
      state.paused = false;

      setState(() {
        _transfers.remove(oldRequestId);
        _transfers[newRequestId] = state;
      });

      _ws!.add(jsonEncode({
        'type': 'file-browser-download',
        'requestId': newRequestId,
        'uri': state.uri,
        'name': state.name,
        'offset': state.received,
      }));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل الاستئناف: $e')),
        );
      }
    }
  }

  Future<void> _cancelTransfer(String requestId) async {
    final state = _transfers[requestId];
    if (state == null) return;

    _ws!.add(jsonEncode({
      'type': 'file-transfer-cancel',
      'requestId': requestId,
    }));

    try { await state.sink?.close(); } catch (_) {}
    state.canceled = true;

    try {
      if (state.tempFile != null && await state.tempFile!.exists()) {
        await state.tempFile!.delete();
      }
    } catch (_) {}

    setState(() => _transfers.remove(requestId));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم إلغاء التحميل وحذف الملف المؤقت'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<Directory?> _askSaveLocation(String fileName) async {
    final downloadsDir = await _getDownloadsDir();
    final appDir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('أين تحفظ الملف؟'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fileName,
                style: const TextStyle(fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.download, color: Colors.green),
              title: const Text('مجلد التنزيلات'),
              subtitle: Text(downloadsDir.path,
                  style: const TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'downloads'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_special, color: Colors.blue),
              title: const Text('مجلد التطبيق الخاص'),
              subtitle: Text(appDir.path, style: const TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'app'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );

    if (choice == 'downloads') return downloadsDir;
    if (choice == 'app') return appDir;
    return null;
  }

  Future<Directory> _getDownloadsDir() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        if (!await downloads.exists()) {
          await downloads.create(recursive: true);
        }
        return downloads;
      }
    } catch (_) {}
    try {
      final legacy = Directory('/storage/emulated/0/Download');
      if (await legacy.exists()) return legacy;
    } catch (_) {}
    return await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
  }

  Future<void> _finishTransfer(
      String requestId, Map<String, dynamic> endMsg) async {
    final state = _transfers[requestId];
    if (state == null) return;
    if (state.canceled) return;

    if (state.mode == TransferMode.preview) {
      final builder = BytesBuilder();
      for (final c in state.chunks) {
        builder.add(c);
      }
      final bytes = builder.toBytes();
      if (!mounted) return;
      setState(() => _transfers.remove(requestId));
      _showPreviewDialog(state.name, state.mime, bytes);
      return;
    }

    if (endMsg['canceled'] == true) {
      return;
    }

    try {
      await state.sink?.flush();
      await state.sink?.close();
      state.sink = null;

      final dir = state.saveDir ?? await _getDownloadsDir();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final safeName = state.name.replaceAll(RegExp(r'[^\w\.\-]'), '_');
      final finalFile = File('${dir.path}/$safeName');

      if (state.tempFile != null && await state.tempFile!.exists()) {
        await state.tempFile!.rename(finalFile.path);
      }

      if (!mounted) return;
      setState(() => _transfers.remove(requestId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تم الحفظ: ${finalFile.path}'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _transfers.remove(requestId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل الحفظ: $e')),
      );
    }
  }

  void _showPreviewDialog(String name, String mime, Uint8List bytes) {
    if (!mounted) return;

    if (mime.startsWith('image/') || _looksLikeImage(name)) {
      showDialog(
        context: context,
        barrierColor: Colors.black,
        builder: (ctx) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 6.0,
                  child: Center(child: Image.memory(bytes)),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white, size: 30),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      name,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      return;
    }

    if (mime.startsWith('video/') || _looksLikeVideo(name)) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('معاينة الفيديو'),
          content: Text(
            'معاينة الفيديو داخل التطبيق غير متاحة حالياً.\n\n'
            'حمّل الملف (${_humanSize(bytes.length)}) ثم افتحه من مجلد التنزيلات.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('حسناً'),
            ),
          ],
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('لا يمكن معاينة هذا النوع من الملفات')),
    );
  }

  bool _looksLikeImage(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.png') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.bmp');
  }

  bool _looksLikeVideo(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.mp4') ||
        n.endsWith('.mov') ||
        n.endsWith('.mkv') ||
        n.endsWith('.webm') ||
        n.endsWith('.avi') ||
        n.endsWith('.3gp');
  }

  Future<void> _loadRoot() async {
    if (_ws?.readyState != WebSocket.open || !_approved) return;
    _startLoadTimeout('جاري قراءة الملفات...');
    _ws!.add(jsonEncode({
      'type': 'file-browser-list',
      'requestId': _uid(),
      'uri': null,
    }));
  }

  void _openPath(String path) {
    if (_ws?.readyState != WebSocket.open || !_approved) return;
    _startLoadTimeout('جاري قراءة المجلد...');
    _ws!.add(jsonEncode({
      'type': 'file-browser-list',
      'requestId': _uid(),
      'uri': path,
    }));
  }

  void _loadGallery(String type) {
    if (_ws?.readyState != WebSocket.open || !_approved) {
      setState(() => _status = 'الجهاز غير جاهز — أعد المحاولة');
      return;
    }
    _startLoadTimeout(
        'جاري تحميل ${type == 'image' ? 'الصور' : 'الفيديو'}...');
    _ws!.add(jsonEncode({
      'type': 'file-browser-list',
      'requestId': _uid(),
      'uri': 'gallery://$type',
    }));
  }

  void _startLoadTimeout(String statusText) {
    _loadTimeout?.cancel();
    setState(() {
      _loading = true;
      _status = statusText;
    });
    _loadTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _status = 'انتهت المهلة — الجهاز لم يستجب';
        });
      }
    });
  }

  static String _uid() =>
      DateTime.now().microsecondsSinceEpoch.toString() +
      '_' +
      (1000 + (DateTime.now().millisecond % 9000)).toString();

  bool get _isInRoot {
    if (_tabs.index == 0) return true;
    final p = _currentPath;
    return p == null || p.isEmpty || p == '/';
  }

  void _goUpOneLevel() {
    final parent = _parentPath;
    if (parent != null && parent.isNotEmpty && parent != '/') {
      _openPath(parent);
    } else {
      _loadRoot();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _isInRoot,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _goUpOneLevel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.name),
          bottom: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'الصور والفيديو', icon: Icon(Icons.photo_library)),
              Tab(text: 'الملفات', icon: Icon(Icons.folder)),
            ],
          ),
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: _approved
                  ? Colors.green.shade100
                  : (_ready
                      ? Colors.red.shade100
                      : Colors.orange.shade100),
              child: Text(
                _status,
                style: const TextStyle(fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
            if (_permissionMissingOnChild)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: Colors.amber.shade100,
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'جهاز الطفل يحتاج تفعيل "الوصول لجميع الملفات"',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _showChildPermissionHelp,
                      child: const Text('كيف؟'),
                    ),
                  ],
                ),
              ),
            if (_transfers.isNotEmpty) _buildTransferBanner(),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildGalleryTab(),
                  _buildFilesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferBanner() {
    final entries = _transfers.entries.toList();
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.blue.shade50,
      child: Column(
        children: entries.map((e) {
          final requestId = e.key;
          final state = e.value;
          final pct = state.size > 0
              ? (state.received / state.size).clamp(0.0, 1.0)
              : null;
          final isPreview = state.mode == TransferMode.preview;
          final isPaused = state.paused;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  isPreview
                      ? Icons.visibility
                      : (isPaused ? Icons.pause_circle : Icons.download),
                  size: 18,
                  color: isPaused ? Colors.orange : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.name,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: pct,
                        color: isPaused ? Colors.orange : null,
                      ),
                      if (state.size > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${(state.received / 1024).toStringAsFixed(0)} / '
                            '${(state.size / 1024).toStringAsFixed(0)} KB'
                            '${isPaused ? " — متوقف" : ""}',
                            style: TextStyle(
                              fontSize: 10,
                              color: isPaused
                                  ? Colors.orange.shade800
                                  : Colors.grey.shade700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!isPreview)
                  IconButton(
                    icon: Icon(
                      isPaused ? Icons.play_arrow : Icons.pause,
                      color: isPaused ? Colors.green : Colors.orange,
                    ),
                    tooltip: isPaused ? 'استئناف' : 'إيقاف مؤقت',
                    onPressed: () {
                      if (isPaused) {
                        _resumeTransfer(requestId);
                      } else {
                        _pauseTransfer(requestId);
                      }
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.red),
                  tooltip: 'إلغاء',
                  onPressed: () => _cancelTransfer(requestId),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGalleryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _approved ? () => _loadGallery('image') : null,
                  icon: const Icon(Icons.photo),
                  label: const Text('الصور'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _approved ? () => _loadGallery('video') : null,
                  icon: const Icon(Icons.videocam),
                  label: const Text('الفيديو'),
                ),
              ),
            ],
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(),
          )
        else if (_galleryItems.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'اختر "الصور" أو "الفيديو"\nلبحث المعرض',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
            ),
          )
        else
          Expanded(child: _buildItemsList(_galleryItems)),
      ],
    );
  }

  Widget _buildFilesTab() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Colors.grey.shade200,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.home),
                tooltip: 'الرئيسي',
                onPressed: _approved ? _loadRoot : null,
              ),
              if (_parentPath != null &&
                  _parentPath!.isNotEmpty &&
                  _parentPath != '/')
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'أعلى',
                  onPressed: () => _openPath(_parentPath!),
                ),
              Expanded(
                child: Text(
                  _currentPath ?? 'الرئيسي',
                  style: const TextStyle(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton.icon(
            onPressed: _showChildPermissionHelp,
            icon: const Icon(Icons.help_outline, size: 18),
            label: const Text('كيف أفعّل الصلاحية على جهاز الطفل؟'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.deepPurple,
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(),
          )
        else if (_fileItems.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_open,
                      size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text(
                    'اضغط "بدء الاستعراض" لتصفح ملفات جهاز الطفل',
                    style: TextStyle(color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _approved ? _loadRoot : null,
                    child: const Text('بدء الاستعراض'),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(child: _buildItemsList(_fileItems)),
      ],
    );
  }

  Widget _buildItemsList(List<Map<String, dynamic>> items) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final name = item['name']?.toString() ?? 'file';
        final uri = item['uri']?.toString() ?? '';
        final isDir = item['isDirectory'] == true;
        final size = (item['size'] as num?)?.toInt() ?? 0;
        final mime = item['mime']?.toString() ?? '';

        return ListTile(
          leading: Icon(
            isDir
                ? Icons.folder
                : (mime.startsWith('image/')
                    ? Icons.image
                    : mime.startsWith('video/')
                        ? Icons.videocam
                        : mime.startsWith('audio/')
                            ? Icons.audiotrack
                            : Icons.insert_drive_file),
            color: isDir ? Colors.amber.shade700 : Colors.blue,
          ),
          title: Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(isDir ? 'مجلد' : _humanSize(size)),
          trailing: isDir
              ? const Icon(Icons.chevron_right)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (mime.startsWith('image/') ||
                        mime.startsWith('video/') ||
                        _looksLikeImage(name) ||
                        _looksLikeVideo(name))
                      IconButton(
                        icon: const Icon(Icons.visibility,
                            color: Colors.deepPurple),
                        tooltip: 'معاينة',
                        onPressed: () => _preview(uri, name, mime),
                      ),
                    IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: 'تنزيل',
                      onPressed: () => _startDownload(uri, name, mime),
                    ),
                  ],
                ),
          onTap: isDir ? () => _openPath(uri) : null,
        );
      },
    );
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}

enum TransferMode { download, preview }

class _TransferState {
  final String name;
  final String uri;
  final TransferMode mode;
  final String mime;
  final Directory? saveDir;

  int size;
  int received;
  bool paused;
  bool canceled;
  File? tempFile;
  IOSink? sink;
  final List<Uint8List> chunks;

  _TransferState({
    required this.name,
    required this.uri,
    required this.mode,
    required this.mime,
    this.saveDir,
    this.size = 0,
    this.received = 0,
    this.paused = false,
    this.canceled = false,
    this.tempFile,
    this.sink,
    List<Uint8List>? chunks,
  }) : chunks = chunks ?? [];
}
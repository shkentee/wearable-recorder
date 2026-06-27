import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_storage_client.dart';

/// Shows files available on the device SD card and allows fetching +
/// uploading them to Google Drive.
class StoragePage extends StatefulWidget {
  const StoragePage({
    super.key,
    required this.device,
    WrDriveUploader? uploader,
    WrStorageSession? session,
  })  : _uploaderOverride = uploader,
        _sessionOverride = session;

  final WrBleDevice device;
  final WrDriveUploader? _uploaderOverride;
  // Injected in tests to bypass real BLE + Drive calls.
  final WrStorageSession? _sessionOverride;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  WrDriveUploader get _uploader =>
      widget._uploaderOverride ?? WrDriveUploader();

  WrStorageSession? _session;
  List<String> _files = [];
  bool _loading = true;
  String? _error;

  // Per-file transfer state: filename → progress message.
  final Map<String, String> _progress = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _session =
          widget._sessionOverride ?? await widget.device.openStorageSession();
      if (_session == null) {
        if (!mounted) return;
        setState(() {
          _error = 'このファームウェアでは本体SD一覧に未対応です。';
          _loading = false;
        });
        return;
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _session!.listFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _fetchAndUpload(String filename, {bool retry = false}) async {
    final current = _progress[filename];
    if (current != null && !(retry && current.startsWith('エラー:'))) {
      return;
    }

    if (!mounted) return;
    setState(() => _progress[filename] = '吸出し中…');
    File? tmp;
    try {
      final dir = await getTemporaryDirectory();
      tmp = File('${dir.path}/$filename');

      await _session!.fetchFileToFile(
        filename,
        tmp,
        onProgress: (n, total) {
          if (!mounted) return;
          final doneKb = (n / 1024).toStringAsFixed(0);
          final totalKb = total == null || total <= 0
              ? ''
              : ' / ${(total / 1024).toStringAsFixed(0)}';
          setState(() => _progress[filename] = '吸出し中… $doneKb$totalKb KB');
        },
      );

      if (!mounted) return;
      setState(() => _progress[filename] = 'アップロード中…');

      await _uploader.uploadFile(tmp, filename);
      await tmp.delete();

      if (!mounted) return;
      setState(() => _progress.remove(filename));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$filename をDriveへアップロードしました')),
      );
    } catch (e) {
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
      if (!mounted) return;
      setState(() => _progress[filename] = 'エラー: $e');
    }
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本体SD'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('読み込みに失敗しました: $_error'),
        ),
      );
    }
    if (_files.isEmpty) {
      return const Center(child: Text('本体SDに .opus ファイルはありません'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _files.length,
        itemBuilder: (context, i) {
          final name = _files[i];
          final prog = _progress[name];
          return ListTile(
            leading: const Icon(Icons.audiotrack),
            title: Text(name),
            subtitle: prog != null ? Text(prog) : null,
            trailing: prog == null
                ? IconButton(
                    icon: const Icon(Icons.cloud_upload_outlined),
                    tooltip: '吸出してDriveへ送る',
                    onPressed: () => _fetchAndUpload(name),
                  )
                : prog.startsWith('エラー:')
                    ? IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.red),
                        tooltip: '再試行',
                        onPressed: () => _fetchAndUpload(name, retry: true),
                      )
                    : const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
          );
        },
      ),
    );
  }
}

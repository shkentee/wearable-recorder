import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import '../services/wr_drive_uploader.dart';

class DriveFilesPage extends StatefulWidget {
  const DriveFilesPage({super.key, WrDriveUploader? uploader})
      : uploaderOverride = uploader;

  final WrDriveUploader? uploaderOverride;

  @override
  State<DriveFilesPage> createState() => _DriveFilesPageState();
}

class _DriveFilesPageState extends State<DriveFilesPage> {
  WrDriveUploader get _uploader => widget.uploaderOverride ?? WrDriveUploader();

  List<drive.File> _files = [];
  bool _loading = true;
  String? _error;
  final Set<String> _deletingIds = {};

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _uploader.listFiles();
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

  Future<void> _delete(drive.File file) async {
    final id = file.id;
    if (id == null || _deletingIds.contains(id)) return;
    setState(() => _deletingIds.add(id));
    try {
      await _uploader.deleteFile(id);
      if (!mounted) return;
      setState(() => _files.remove(file));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('削除に失敗しました: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingIds.remove(id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drive録音'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadFiles,
            tooltip: '更新',
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
      return Center(child: Text('読み込みに失敗しました: $_error'));
    }
    if (_files.isEmpty) {
      return const Center(child: Text('Driveに録音はまだありません'));
    }
    return RefreshIndicator(
      onRefresh: _loadFiles,
      child: ListView.builder(
        itemCount: _files.length,
        itemBuilder: (context, i) {
          final file = _files[i];
          final deleting = file.id != null && _deletingIds.contains(file.id);
          return ListTile(
            leading: const Icon(Icons.audiotrack),
            title: Text(file.name ?? '名称なし'),
            subtitle: file.modifiedTime != null
                ? Text(file.modifiedTime!.toLocal().toString())
                : null,
            trailing: deleting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(file),
                    tooltip: '削除',
                  ),
          );
        },
      ),
    );
  }
}

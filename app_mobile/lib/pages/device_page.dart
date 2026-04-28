import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_foreground_service.dart';
import 'drive_files_page.dart';
import 'storage_page.dart';

/// SharedPreferences key used to persist the last-connected device address.
const _kLastDeviceId = 'wr_last_device_id';

class DevicePage extends StatefulWidget {
  const DevicePage({
    super.key,
    required this.device,
    WrDriveUploader? uploader,
  }) : uploaderOverride = uploader;

  final WrBleDevice device;
  // Allow injection in tests; production code uses the default instance.
  final WrDriveUploader? uploaderOverride;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  String _status = 'connecting…';
  int _packets = 0;
  int _savedBytes = 0;
  int _lostPackets = 0;
  bool _uploading = false;

  WrDriveUploader get _uploader =>
      widget.uploaderOverride ?? WrDriveUploader();

  @override
  void initState() {
    super.initState();
    widget.device.state.listen((s) {
      if (!mounted) return;
      setState(() => _status = s.name);
      if (s == BluetoothConnectionState.disconnected) {
        WrForegroundService.stop().ignore();
      }
    });
    widget.device.packetCount.listen((n) {
      if (!mounted) return;
      setState(() => _packets = n);
      if (n % 100 == 0 && n > 0) {
        WrForegroundService.update(
          '${widget.device.name} · $n packets',
        ).ignore();
      }
    });
    widget.device.bytesSaved.listen((n) {
      if (!mounted) return;
      setState(() => _savedBytes = n);
    });
    widget.device.lostPackets.listen((n) {
      if (!mounted) return;
      setState(() => _lostPackets = n);
    });
    _connect();
  }

  Future<void> _connect() async {
    try {
      await widget.device.connect();
      await WrForegroundService.start(widget.device.name);
      // Persist the device address so ScanPage can auto-reconnect next launch.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastDeviceId, widget.device.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error: $e');
    }
  }

  Future<void> _uploadToDriver() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      // Resolve the same dump-file path used by WrBleDevice._defaultSink().
      final dir = await getApplicationDocumentsDirectory();
      final id = widget.device.id;
      // Find the most-recently modified dump file for this device.
      final dumpDir = Directory('${dir.path}/wr_dumps');
      File? dumpFile;
      if (await dumpDir.exists()) {
        final candidates = await dumpDir
            .list()
            .where((e) => e is File && e.path.contains(id))
            .cast<File>()
            .toList();
        if (candidates.isNotEmpty) {
          candidates.sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
          dumpFile = candidates.first;
        }
      }

      if (dumpFile == null) {
        _showSnackBar('No dump file found for this device.', isError: true);
        return;
      }

      final remoteName =
          '${id.replaceAll(':', '-')}-${DateTime.now().millisecondsSinceEpoch}.opus';
      final fileId = await _uploader.uploadFile(dumpFile, remoteName);
      _showSnackBar('Uploaded! Drive ID: $fileId');
    } catch (e) {
      _showSnackBar('Upload failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  @override
  void dispose() {
    WrForegroundService.stop().ignore();
    widget.device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.sd_storage_outlined),
            tooltip: 'Device SD files',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StoragePage(
                  device: widget.device,
                  uploader: _uploader,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.cloud_queue),
            tooltip: 'Drive recordings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DriveFilesPage(uploader: _uploader),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('id: ${widget.device.id}'),
            const SizedBox(height: 8),
            Text('status: $_status'),
            const SizedBox(height: 8),
            Text('audioCodec packets: $_packets',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('Saved bytes: $_savedBytes',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Lost: $_lostPackets',
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            const Text(
              'Phase 6 MVP: notify subscription + raw dump. Opus decode '
              'runs offline on a paired PC.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _uploadToDriver,
        icon: _uploading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.cloud_upload),
        label: Text(_uploading ? 'Uploading…' : 'Upload to Drive'),
        tooltip: 'Upload latest dump file to Google Drive',
      ),
    );
  }
}

extension on BluetoothConnectionState {
  String get name => switch (this) {
        BluetoothConnectionState.connected => 'connected',
        BluetoothConnectionState.disconnected => 'disconnected',
        _ => toString(),
      };
}

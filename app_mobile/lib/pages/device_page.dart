import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_foreground_service.dart';
import 'drive_files_page.dart';
import 'recordings_page.dart';
import 'settings_page.dart';
import 'storage_page.dart';

/// SharedPreferences key used to persist the last-connected device address.
const _kLastDeviceId = 'wr_last_device_id';

/// SharedPreferences key for the auto-upload-on-disconnect toggle.
const _kAutoUpload = 'wr_auto_upload';

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
  int? _batteryPct; // null until first Battery Service notify/read
  double _level = 0.0; // live mic level 0..1
  bool? _recording; // device SD recording on/off; null = unsupported firmware
  bool _uploading = false;
  bool _autoUpload = true; // auto-upload completed recordings to Drive
  bool _autoUploadBusy = false;

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
        // The session's dump file is now complete — auto-upload it.
        _autoUploadSync();
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
    widget.device.batteryLevel.listen((pct) {
      if (!mounted) return;
      setState(() => _batteryPct = pct);
    });
    widget.device.audioLevel.listen((lvl) {
      if (!mounted) return;
      setState(() => _level = lvl);
    });
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _autoUpload = prefs.getBool(_kAutoUpload) ?? true);
    }
    await _connect();
  }

  Future<void> _connect() async {
    try {
      await widget.device.connect();
      await WrForegroundService.start(widget.device.name);
      // Persist the device address so ScanPage can auto-reconnect next launch.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastDeviceId, widget.device.id);
      // Reflect the device's current recording on/off state (if supported).
      final rec = await widget.device.readRecordingState();
      if (mounted) setState(() => _recording = rec);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error: $e');
    }
  }

  /// Builds the Drive remote name from a local dump path:
  /// `FF:94:..-<stamp>.bin` -> `FF-94-..-<stamp>.opus`.
  String _remoteName(File f) => f.uri.pathSegments.last
      .replaceAll(':', '-')
      .replaceAll('.bin', '.opus');

  /// On disconnect, auto-upload the recording from the session that just
  /// ended (idempotent via the uploader's dedup). Only the just-finished file
  /// is uploaded — historical recordings stay local unless uploaded manually
  /// from the Recordings page.
  Future<void> _autoUploadSync() async {
    if (!_autoUpload || _autoUploadBusy) return;
    _autoUploadBusy = true;
    try {
      // Flush/close the just-finished dump before reading it. (No-op for the
      // BLE link if it's already down.)
      await widget.device.disconnect();
      final path = widget.device.lastDumpPath;
      if (path == null) return;
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) return;
      final id = await _uploader.uploadIfNew(file, _remoteName(file));
      if (id != null && mounted) {
        _showSnackBar('Auto-uploaded recording to Drive');
      }
    } catch (_) {
      // Best-effort; the file stays local and can be uploaded manually.
    } finally {
      _autoUploadBusy = false;
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
          if (_batteryPct != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _batteryPct! >= 80
                        ? Icons.battery_full
                        : _batteryPct! >= 40
                            ? Icons.battery_4_bar
                            : Icons.battery_alert,
                    color: _batteryPct! < 20 ? Colors.red : null,
                    size: 20,
                  ),
                  const SizedBox(width: 2),
                  Text('$_batteryPct%',
                      style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
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
            icon: const Icon(Icons.library_music_outlined),
            tooltip: 'Recordings (play)',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RecordingsPage(uploader: _uploader),
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
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsPage(uploader: _uploader),
                ),
              );
              // Re-read the auto-upload preference in case it changed.
              final prefs = await SharedPreferences.getInstance();
              if (mounted) {
                setState(
                    () => _autoUpload = prefs.getBool(_kAutoUpload) ?? true);
              }
            },
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
            const SizedBox(height: 24),
            const Row(
              children: [
                Icon(Icons.mic, size: 20),
                SizedBox(width: 8),
                Text('Mic level'),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _level,
                minHeight: 16,
                backgroundColor: Colors.grey.shade300,
                valueColor: AlwaysStoppedAnimation<Color>(
                  _level > 0.85
                      ? Colors.red
                      : _level > 0.5
                          ? Colors.orange
                          : Colors.green,
                ),
              ),
            ),
            if (_recording != null) ...[
              const SizedBox(height: 20),
              Card(
                margin: EdgeInsets.zero,
                child: SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  secondary: Icon(
                    _recording! ? Icons.fiber_manual_record : Icons.stop_circle_outlined,
                    color: _recording! ? Colors.red : null,
                  ),
                  title: const Text('Recording to SD'),
                  subtitle: Text(
                      _recording! ? 'On — saving on device' : 'Off — paused'),
                  value: _recording!,
                  onChanged: (v) async {
                    setState(() => _recording = v); // optimistic
                    try {
                      await widget.device.setRecording(v);
                    } catch (e) {
                      if (mounted) {
                        setState(() => _recording = !v); // revert on failure
                        _showSnackBar('Failed to ${v ? 'start' : 'stop'} recording: $e',
                            isError: true);
                      }
                    }
                  },
                ),
              ),
            ],
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

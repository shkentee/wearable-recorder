import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_foreground_service.dart';
import '../services/wr_sd_sync.dart';
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
  int? _gainQ4; // mic capture gain, Q4 (16 = 1.0x); null = unsupported firmware
  bool _uploading = false;
  bool _autoUpload = true; // auto-sync completed SD chunks to Drive
  WrSdSync? _sdSync;
  String? _syncStatus; // last SD-sync event, shown in the UI

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
        _sdSync?.stop();
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
      // Reflect the device's current mic gain (if supported).
      final gain = await widget.device.readGainQ4();
      if (mounted) setState(() => _gainQ4 = gain);
      // Start pulling completed SD chunks -> Drive for transcription.
      _startSdSyncIfEnabled();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error: $e');
    }
  }

  /// Starts the background SD-chunk -> Drive sync (if auto-upload is enabled).
  /// The device records ~10-min chunks to SD; this fetches completed ones and
  /// uploads them, so transcription gets near-real-time, loss-tolerant audio.
  void _startSdSyncIfEnabled() {
    _sdSync?.stop();
    if (!_autoUpload) return;
    final sync = WrSdSync(device: widget.device, uploader: _uploader);
    sync.events.listen((msg) {
      if (mounted) setState(() => _syncStatus = msg);
    });
    sync.start();
    _sdSync = sync;
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

  Future<void> _sleepDevice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sleep device?'),
        content: const Text(
            'The device powers down to save battery. Press its button to '
            'wake it (it restarts and resumes recording).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sleep')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final sent = await widget.device.sleepDevice();
      _showSnackBar(sent
          ? 'Sleep command sent — device powering down'
          : 'Sleep not supported by this firmware', isError: !sent);
    } catch (_) {
      // The link drops as the device powers off — expected.
      _showSnackBar('Sleep command sent — device powering down');
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
    _sdSync?.dispose();
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
          if (_recording != null)
            IconButton(
              icon: const Icon(Icons.bedtime_outlined),
              tooltip: 'Sleep device',
              onPressed: _sleepDevice,
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
              // Re-read the auto-upload preference in case it changed, and
              // start/stop the SD-chunk sync to match.
              final prefs = await SharedPreferences.getInstance();
              if (mounted) {
                setState(
                    () => _autoUpload = prefs.getBool(_kAutoUpload) ?? true);
                _startSdSyncIfEnabled();
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
            if (_gainQ4 != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.tune, size: 20),
                  const SizedBox(width: 8),
                  const Text('Mic gain'),
                  const Spacer(),
                  Text('${(_gainQ4! / 16).toStringAsFixed(2)}x',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              Slider(
                min: 4, // 0.25x
                max: 128, // 8.0x
                divisions: 31, // steps of 4 (0.25x)
                value: _gainQ4!.clamp(4, 128).toDouble(),
                label: '${(_gainQ4! / 16).toStringAsFixed(2)}x',
                onChanged: (v) => setState(() => _gainQ4 = v.round()),
                onChangeEnd: (v) async {
                  final g = v.round();
                  try {
                    await widget.device.setGainQ4(g);
                  } catch (e) {
                    _showSnackBar('Failed to set gain: $e', isError: true);
                  }
                },
              ),
            ],
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
            Row(
              children: [
                Icon(
                  _autoUpload
                      ? Icons.cloud_sync_outlined
                      : Icons.cloud_off_outlined,
                  size: 18,
                  color: _autoUpload
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _autoUpload
                        ? 'Drive auto-sync: ${_syncStatus ?? 'on'}'
                        : 'Drive auto-sync: off',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_foreground_service.dart';
import '../services/wr_sd_sync.dart';
import '../widgets/brand.dart';
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
  final List<double> _levels = []; // rolling buffer for the live waveform
  bool _liveMonitor = false; // live audio subscription (off by default; power)
  bool? _recording; // device SD recording on/off; null = unsupported firmware
  int? _gainQ4; // mic capture gain, Q4 (16 = 1.0x); null = unsupported firmware
  bool _uploading = false;
  bool _autoUpload = true; // auto-sync completed SD chunks to Drive
  WrSdSync? _sdSync;
  String? _syncStatus; // last SD-sync event, shown in the UI
  WrSyncProgress? _syncProg; // live backlog / pull progress, shown in the UI

  WrDriveUploader get _uploader => widget.uploaderOverride ?? WrDriveUploader();

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
      setState(() {
        _level = lvl;
        _levels.add(lvl);
        if (_levels.length > 96) _levels.removeAt(0);
      });
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
    sync.progress.listen((p) {
      if (mounted) setState(() => _syncProg = p);
    });
    sync.start();
    _sdSync = sync;
  }

  String _fmtMB(int b) => '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';

  String _fmtDur(int secs) {
    if (secs < 60) return '${secs}s';
    final m = secs ~/ 60;
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}m';
  }

  /// Drive auto-sync read-out: backlog (un-fetched bytes still on the device),
  /// current pull rate, and a progress bar. Falls back to a one-line status
  /// before the first progress event arrives.
  Widget _buildSyncStatus() {
    final dim = Theme.of(context).colorScheme.onSurface.withOpacity(0.6);
    if (!_autoUpload) {
      return Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: dim),
          const SizedBox(width: 8),
          Text('Drive自動同期：オフ', style: TextStyle(fontSize: 13, color: dim)),
        ],
      );
    }
    final p = _syncProg;
    if (p == null || p.committed == 0) {
      return Row(
        children: [
          Icon(Icons.cloud_sync_outlined,
              size: 18, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Drive自動同期：${_syncStatus ?? '待機中'}',
                style: const TextStyle(fontSize: 13)),
          ),
        ],
      );
    }
    final pct = (p.synced / p.committed).clamp(0.0, 1.0);
    final backlogSecs = (p.backlogBytes / 4000).round(); // ~4000 B/s of audio
    final rateKB = p.bytesPerSec / 1024;
    final caught = p.caughtUp;
    final cs = Theme.of(context).colorScheme;

    // Header: a live spinner + bold「取得中」while pulling, a check when caught
    // up, or「待機中」when the schedule has it paused — so the state is obvious.
    Widget header;
    if (caught) {
      header = Row(children: [
        Icon(Icons.cloud_done_outlined, size: 18, color: cs.secondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text('同期済み — 最新です（${p.uploadedChunks}件アップ済み）',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ]);
    } else if (p.fetching) {
      header = Row(children: [
        SizedBox(
          width: 16,
          height: 16,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: cs.secondary),
        ),
        const SizedBox(width: 10),
        Text('取得中',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: cs.secondary)),
        const Spacer(),
        Text('${rateKB.toStringAsFixed(1)} KB/s',
            style: TextStyle(fontSize: 12, color: dim)),
      ]);
    } else {
      header = Row(children: [
        Icon(Icons.pause_circle_outline, size: 18, color: dim),
        const SizedBox(width: 8),
        Expanded(
          child: Text('待機中（スケジュール待ち）',
              style: TextStyle(fontSize: 13, color: dim)),
        ),
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 8),
        GradientProgressBar(value: pct, height: 8),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('${_fmtMB(p.synced)} / ${_fmtMB(p.committed)}',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('(${(pct * 100).toStringAsFixed(1)}%)',
                style: TextStyle(fontSize: 12, color: dim)),
            const Spacer(),
            if (!caught)
              Text('残り ${_fmtMB(p.backlogBytes)}（〜${_fmtDur(backlogSecs)}）',
                  style: TextStyle(fontSize: 12, color: dim)),
          ],
        ),
      ],
    );
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
      _showSnackBar(
          sent
              ? 'Sleep command sent — device powering down'
              : 'Sleep not supported by this firmware',
          isError: !sent);
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

  Widget _card(Widget child) => Card(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurface.withOpacity(0.6);
    final connected = _status == 'connected';
    final statusJa = _status == 'connected'
        ? '接続中'
        : _status == 'disconnected'
            ? '未接続'
            : '接続中…';
    return Scaffold(
      appBar: AppBar(
        title: const MojioWordmark(fontSize: 24),
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
                  Text('$_batteryPct%', style: const TextStyle(fontSize: 13)),
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          // ---- デバイスカード（製品写真） ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: 72,
                      height: 72,
                      color: Colors.white,
                      child: Image.asset('assets/mojio_device.png',
                          fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Mojio Device',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: connected ? cs.secondary : Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(statusJa,
                                style: TextStyle(color: dim, fontSize: 13)),
                            const Spacer(),
                            if (_batteryPct != null) ...[
                              Icon(
                                _batteryPct! >= 80
                                    ? Icons.battery_full
                                    : _batteryPct! >= 40
                                        ? Icons.battery_4_bar
                                        : Icons.battery_alert,
                                size: 16,
                                color: _batteryPct! < 20 ? cs.error : dim,
                              ),
                              const SizedBox(width: 2),
                              Text('$_batteryPct%',
                                  style: TextStyle(color: dim, fontSize: 13)),
                            ],
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '受信 $_packets ・ 保存 ${_fmtMB(_savedBytes)} ・ ロスト $_lostPackets',
                          style: TextStyle(fontSize: 11, color: dim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.mic, size: 20, color: cs.secondary),
                    const SizedBox(width: 8),
                    const Text('マイク入力',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('ライブモニター', style: TextStyle(fontSize: 12, color: dim)),
                    Switch(
                      value: _liveMonitor,
                      onChanged: (v) async {
                        setState(() {
                          _liveMonitor = v;
                          if (!v) {
                            _level = 0.0;
                            _levels.clear();
                          }
                        });
                        try {
                          await widget.device.setLiveMonitor(v);
                        } catch (_) {}
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                WaveformBars(
                    levels: _liveMonitor ? _levels : const [], height: 56),
                if (!_liveMonitor)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('オフ — マイク確認時だけオンに（省電力）',
                        style: TextStyle(fontSize: 11, color: dim)),
                  ),
              ],
            ),
          ),
          if (_gainQ4 != null) ...[
            const SizedBox(height: 14),
            _card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tune, size: 20, color: cs.secondary),
                      const SizedBox(width: 8),
                      const Text('マイクゲイン',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text('${(_gainQ4! / 16).toStringAsFixed(2)}x',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LevelMeter(level: _liveMonitor ? _level : 0.0, height: 12),
                  if (!_liveMonitor)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('ライブモニターをオンにすると入力レベルを見ながら調整できます',
                          style: TextStyle(fontSize: 11, color: dim)),
                    ),
                  Slider(
                    min: 4,
                    max: 128,
                    divisions: 31,
                    value: _gainQ4!.clamp(4, 128).toDouble(),
                    label: '${(_gainQ4! / 16).toStringAsFixed(2)}x',
                    onChanged: (v) => setState(() => _gainQ4 = v.round()),
                    onChangeEnd: (v) async {
                      final g = v.round();
                      try {
                        await widget.device.setGainQ4(g);
                      } catch (e) {
                        _showSnackBar('ゲイン設定に失敗しました: $e', isError: true);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
          if (_recording != null) ...[
            const SizedBox(height: 14),
            Card(
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                secondary: Icon(
                  _recording!
                      ? Icons.fiber_manual_record
                      : Icons.stop_circle_outlined,
                  color: _recording! ? cs.error : null,
                ),
                title: const Text('SDに録音'),
                subtitle: Text(_recording! ? 'オン — 本体に保存中' : 'オフ — 一時停止'),
                value: _recording!,
                onChanged: (v) async {
                  setState(() => _recording = v);
                  try {
                    await widget.device.setRecording(v);
                  } catch (e) {
                    if (mounted) {
                      setState(() => _recording = !v);
                      _showSnackBar('録音の${v ? '開始' : '停止'}に失敗しました: $e',
                          isError: true);
                    }
                  }
                },
              ),
            ),
          ],
          const SizedBox(height: 14),
          _card(_buildSyncStatus()),
        ],
      ),
      floatingActionButton: GradientButton(
        onPressed: _uploading ? null : _uploadToDriver,
        icon: _uploading ? null : Icons.cloud_upload,
        label: _uploading ? 'アップロード中…' : 'Driveにアップロード',
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

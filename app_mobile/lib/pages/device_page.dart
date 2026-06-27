import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_foreground_service.dart';
import '../services/wr_sd_sync.dart';
import '../services/wr_sync_schedule.dart';
import '../widgets/brand.dart';
import 'drive_files_page.dart';
import 'recordings_page.dart';
import 'settings_page.dart';
import 'storage_page.dart';
import 'transcripts_page.dart';

/// SharedPreferences key used to persist the last-connected device address.
const _kLastDeviceId = 'wr_last_device_id';
const _micGainLabels = [
  'ミュート',
  '-20dB',
  '-10dB',
  '0dB',
  '+6dB',
  '+10dB',
  '+20dB',
  '+30dB',
  '+40dB',
];

enum _DeviceMenuAction {
  recordings,
  drive,
  transcripts,
  sleep,
}

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
  int? _micGainLevel; // Omi mic gain level 0..8; null = unsupported firmware
  bool _driveUploadAuto = true;
  SyncSchedule _schedule = const SyncSchedule();
  WrSdSync? _sdSync;
  String? _syncStatus; // last SD-sync event, shown in the UI
  WrSyncProgress? _syncProg; // live backlog / pull progress, shown in the UI
  WrUploadStatus? _driveStatus; // Drive upload queue state
  final List<StreamSubscription<dynamic>> _deviceSubs = [];
  final List<StreamSubscription<dynamic>> _syncSubs = [];

  WrDriveUploader get _uploader => widget.uploaderOverride ?? WrDriveUploader();

  @override
  void initState() {
    super.initState();
    _deviceSubs.add(widget.device.state.listen((s) {
      if (!mounted) return;
      setState(() => _status = s.name);
      if (s == BluetoothConnectionState.disconnected) {
        WrForegroundService.stop().ignore();
        _sdSync?.stop();
      }
    }));
    _deviceSubs.add(widget.device.packetCount.listen((n) {
      if (!mounted) return;
      setState(() => _packets = n);
      if (n % 100 == 0 && n > 0) {
        WrForegroundService.update(
          '${widget.device.name} · $n packets',
        ).ignore();
      }
    }));
    _deviceSubs.add(widget.device.bytesSaved.listen((n) {
      if (!mounted) return;
      setState(() => _savedBytes = n);
    }));
    _deviceSubs.add(widget.device.lostPackets.listen((n) {
      if (!mounted) return;
      setState(() => _lostPackets = n);
    }));
    _deviceSubs.add(widget.device.batteryLevel.listen((pct) {
      if (!mounted) return;
      setState(() => _batteryPct = pct);
    }));
    _deviceSubs.add(widget.device.audioLevel.listen((lvl) {
      if (!mounted) return;
      setState(() {
        _level = lvl;
        _levels.add(lvl);
        if (_levels.length > 96) _levels.removeAt(0);
      });
    }));
    _init();
  }

  Future<void> _init() async {
    await _loadSyncSettings();
    await _connect();
  }

  Future<void> _loadSyncSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final schedule = await SyncSchedule.load();
    if (!mounted) return;
    setState(() {
      _driveUploadAuto = prefs.getBool(kDriveUploadAutoKey) ?? true;
      _schedule = schedule;
    });
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
      final gain = await widget.device.readMicGainLevel();
      if (mounted) setState(() => _micGainLevel = gain);
      // Start SD pull + Drive upload service. Modes decide whether each side
      // runs automatically or waits for a card button.
      _startSdSync();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error: $e');
    }
  }

  /// Starts the background SD-pull + Drive-upload coordinator.
  void _startSdSync() {
    for (final sub in _syncSubs) {
      sub.cancel().ignore();
    }
    _syncSubs.clear();
    _sdSync?.stop();
    _sdSync = null;
    final sync = WrSdSync(device: widget.device, uploader: _uploader);
    _syncSubs.add(sync.events.listen((msg) {
      if (mounted) setState(() => _syncStatus = msg);
    }));
    _syncSubs.add(sync.progress.listen((p) {
      if (mounted) setState(() => _syncProg = p);
    }));
    _syncSubs.add(sync.uploadStatus.listen((s) {
      if (mounted) setState(() => _driveStatus = s);
    }));
    sync.start();
    _sdSync = sync;
    if (mounted) setState(() {});
  }

  String _fmtMB(int b) => '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';

  double _progressValue(int done, int total) {
    if (total <= 0) return 0;
    return (done / total).clamp(0.0, 1.0);
  }

  String _progressText(int done, int total) {
    final pct = _progressValue(done, total) * 100;
    return '${_fmtMB(done)} / ${_fmtMB(total)}  ${pct.toStringAsFixed(0)}%完了';
  }

  String _pullModeText() => switch (_schedule.mode) {
        SyncMode.manual => '手動',
        SyncMode.scheduledTime =>
          '接続中：毎日 ${SyncSchedule.fmtHm(_schedule.timeMinutes)}',
        SyncMode.intervalWindow =>
          'タイマー：${SyncSchedule.fmtHm(_schedule.windowStartMin)}〜${SyncSchedule.fmtHm(_schedule.windowEndMin)} / ${_schedule.intervalMin}分間隔',
        SyncMode.continuous => '自動：常時',
      };

  Widget _sectionTitle({
    required IconData icon,
    required String title,
    required String mode,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurface.withOpacity(0.6);
    return Row(
      children: [
        Icon(icon, size: 20, color: cs.secondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: cs.secondary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(mode, style: TextStyle(fontSize: 12, color: dim)),
        ),
      ],
    );
  }

  Widget _buildProgressBlock({
    required int done,
    required int total,
    required String status,
  }) {
    final dim = Theme.of(context).colorScheme.onSurface.withOpacity(0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status, style: TextStyle(fontSize: 13, color: dim)),
        const SizedBox(height: 8),
        GradientProgressBar(value: _progressValue(done, total), height: 8),
        const SizedBox(height: 6),
        Text(_progressText(done, total),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildSyncStatus() {
    final p = _syncProg;
    final done = p?.synced ?? 0;
    final total = p?.committed ?? 0;
    final status = p == null
        ? '待機中${_syncStatus == null ? '' : '（$_syncStatus）'}'
        : p.fetching
            ? '吸出し中 ${p.bytesPerSec > 0 ? '(${(p.bytesPerSec / 1024).toStringAsFixed(1)} KB/s)' : ''}'
            : p.caughtUp
                ? '最新まで吸出し済み'
                : '待機中（${_fmtMB(p.backlogBytes)}未吸出し）';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          icon: Icons.sd_storage_outlined,
          title: '吸出し',
          mode: _pullModeText(),
        ),
        const SizedBox(height: 12),
        _buildProgressBlock(done: done, total: total, status: status),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: GradientButton(
            onPressed: _status == 'connected' && _sdSync != null
                ? () {
                    _sdSync?.triggerManualPull();
                    _showSnackBar('吸出しを開始します…');
                  }
                : null,
            icon: Icons.download,
            label: '手動吸出し',
          ),
        ),
      ],
    );
  }

  Widget _buildUploadStatus() {
    final us = _driveStatus;
    final auto = us?.autoUpload ?? _driveUploadAuto;
    final done = us?.completedBytes ?? 0;
    final total = us?.totalBytes ?? 0;
    final status = us == null
        ? '待機中'
        : us.blockedNoWifi
            ? 'WiFi待ち（WiFiのみモード）'
            : us.uploading
                ? 'アップロード中：${us.currentFile ?? ''}'
                : us.waitingForManual
                    ? '手動待ち（未アップロード ${us.pendingFiles}件）'
                    : us.pendingFiles > 0
                        ? '待機中（未アップロード ${us.pendingFiles}件）'
                        : '未アップロードなし';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          icon: Icons.cloud_upload_outlined,
          title: 'Driveアップロード',
          mode: auto ? '自動' : '手動',
        ),
        const SizedBox(height: 12),
        _buildProgressBlock(done: done, total: total, status: status),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: GradientButton(
            onPressed: _status == 'connected' && _sdSync != null
                ? () {
                    _sdSync?.triggerManualUpload();
                    _showSnackBar('Drive同期を開始します…');
                  }
                : null,
            icon: Icons.cloud_upload,
            label: '手動同期',
          ),
        ),
      ],
    );
  }

  Future<void> _sleepDevice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('スリープしますか？'),
        content: const Text(
          '録音機の電源を切って節電します。再開するには本体ボタンを押してください。'
          '起動後、録音を再開します。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('スリープ')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final sent = await widget.device.sleepDevice();
      _showSnackBar(sent ? 'スリープ指示を送信しました' : 'このファームウェアはスリープに未対応です',
          isError: !sent);
    } catch (_) {
      // The link drops as the device powers off.
      _showSnackBar('スリープ指示を送信しました');
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

  void _openStoragePage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoragePage(
          device: widget.device,
          uploader: _uploader,
        ),
      ),
    );
  }

  void _openRecordingsPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecordingsPage(uploader: _uploader),
      ),
    );
  }

  void _openDriveFilesPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DriveFilesPage(uploader: _uploader),
      ),
    );
  }

  void _openTranscriptsPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TranscriptsPage(uploader: _uploader),
      ),
    );
  }

  Future<void> _openSettingsPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(uploader: _uploader),
      ),
    );
    if (mounted) {
      await _loadSyncSettings();
      _startSdSync();
    }
  }

  void _handleMenuAction(_DeviceMenuAction action) {
    switch (action) {
      case _DeviceMenuAction.recordings:
        _openRecordingsPage();
      case _DeviceMenuAction.drive:
        _openDriveFilesPage();
      case _DeviceMenuAction.transcripts:
        _openTranscriptsPage();
      case _DeviceMenuAction.sleep:
        _sleepDevice();
    }
  }

  @override
  void dispose() {
    for (final sub in _deviceSubs) {
      sub.cancel().ignore();
    }
    _deviceSubs.clear();
    for (final sub in _syncSubs) {
      sub.cancel().ignore();
    }
    _syncSubs.clear();
    _sdSync?.dispose().ignore();
    WrForegroundService.stop().ignore();
    widget.device.dispose().ignore();
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
            : _status.startsWith('error:')
                ? _status
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
            tooltip: '本体SD',
            onPressed: _openStoragePage,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: _openSettingsPage,
          ),
          PopupMenuButton<_DeviceMenuAction>(
            tooltip: 'その他',
            icon: const Icon(Icons.more_vert),
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _DeviceMenuAction.recordings,
                child: ListTile(
                  leading: Icon(Icons.library_music_outlined),
                  title: Text('録音を再生'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _DeviceMenuAction.drive,
                child: ListTile(
                  leading: Icon(Icons.cloud_queue),
                  title: Text('Drive録音'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _DeviceMenuAction.transcripts,
                child: ListTile(
                  leading: Icon(Icons.description_outlined),
                  title: Text('トランスクリプト'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (_recording != null)
                const PopupMenuItem(
                  value: _DeviceMenuAction.sleep,
                  child: ListTile(
                    leading: Icon(Icons.bedtime_outlined),
                    title: Text('スリープ'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
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
          if (_micGainLevel != null) ...[
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
                      Text(_micGainLabel(_micGainLevel!),
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
                    min: 0,
                    max: 8,
                    divisions: 8,
                    value: _micGainLevel!.clamp(0, 8).toDouble(),
                    label: _micGainLabel(_micGainLevel!),
                    onChanged: (v) => setState(() => _micGainLevel = v.round()),
                    onChangeEnd: (v) async {
                      final g = v.round();
                      try {
                        await widget.device.setMicGainLevel(g);
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
          const SizedBox(height: 14),
          _card(_buildUploadStatus()),
        ],
      ),
    );
  }
}

String _micGainLabel(int level) {
  final i = level.clamp(0, _micGainLabels.length - 1);
  return _micGainLabels[i];
}

extension on BluetoothConnectionState {
  String get name => switch (this) {
        BluetoothConnectionState.connected => 'connected',
        BluetoothConnectionState.disconnected => 'disconnected',
        _ => toString(),
      };
}

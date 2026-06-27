import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_ble_scanner.dart';
import 'device_page.dart';

/// SharedPreferences key used to persist / retrieve the last-connected device.
const _kLastDeviceId = 'wr_last_device_id';

class ScanPage extends StatefulWidget {
  /// [scannerFactory] is an optional dependency-injection seam used by
  /// widget tests to swap in a fake [WrBleScanner]. Production callers
  /// (main.dart) leave it null and the page constructs a real scanner.
  const ScanPage({super.key, this.scannerFactory});

  final WrBleScanner Function()? scannerFactory;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  late final WrBleScanner _scanner =
      widget.scannerFactory?.call() ?? WrBleScanner();
  StreamSubscription<List<ScanResult>>? _sub;
  List<ScanResult> _results = const [];
  String? _error;

  /// Display name used in the "Auto-connecting to …" indicator.
  String? _autoConnectName;

  @override
  void initState() {
    super.initState();
    _sub = _scanner.results.listen(
      (rs) {
        if (!mounted) return;
        setState(() => _results = rs);
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _error = e.toString());
      },
    );
    _startAutoConnectIfNeeded();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scanner.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Auto-connect logic
  // ---------------------------------------------------------------------------

  Future<void> _startAutoConnectIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_kLastDeviceId);
      if (savedId == null || savedId.isEmpty) return;
      if (!mounted) return;

      setState(() {
        _autoConnectName = savedId;
      });

      final ok = await _ensurePermissions();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _autoConnectName = null;
          _error = 'Bluetooth/位置情報の権限が必要です';
        });
        return;
      }

      // On some Android/Windows combinations the device is connectable by its
      // known remoteId even when it does not appear in fresh scan results.
      // Prefer that path for the previously connected recorder, then leave the
      // normal scan button as the manual fallback if the device page reports an
      // error.
      final device = BluetoothDevice.fromId(savedId);
      setState(() {
        _autoConnectName = null;
      });
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DevicePage(device: WrBleDevice(device)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '自動接続に失敗しました: $e';
      });
    } finally {
      if (mounted && _autoConnectName != null) {
        setState(() => _autoConnectName = null);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Manual scan + navigation
  // ---------------------------------------------------------------------------

  Future<void> _toggleScan() async {
    if (_scanner.isScanning) {
      await _scanner.stop();
      if (mounted) setState(() {});
      return;
    }

    setState(() => _error = null);
    final ok = await _ensurePermissions();
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = 'Bluetooth/位置情報の権限が必要です');
      return;
    }
    try {
      await _scanner.start();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '検索に失敗しました: $e');
      return;
    }
    if (mounted) setState(() {});
  }

  Future<bool> _ensurePermissions() async {
    final perms = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return perms.values.every((s) => s.isGranted || s.isLimited);
  }

  Future<void> _openResult(ScanResult r) async {
    await _scanner.stop();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DevicePage(device: WrBleDevice(r.device)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final autoName = _autoConnectName;
    final isScanning = _scanner.isScanning;
    return Scaffold(
      appBar: AppBar(
        title: const Text('wearable-recorder'),
        actions: [
          IconButton(
            icon: Icon(isScanning ? Icons.stop : Icons.search),
            onPressed: _toggleScan,
            tooltip: isScanning ? '検索を停止' : '録音機を検索',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              color: Colors.red.shade50,
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (autoName != null)
            Container(
              color: Colors.blue.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Auto-connecting to $autoName...',
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      isScanning ? '録音機を検索中…' : '検索して録音機を探す',
                    ),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final name = r.device.platformName.isEmpty
                          ? '(unnamed)'
                          : r.device.platformName;
                      return ListTile(
                        title: Text(name),
                        subtitle:
                            Text('${r.device.remoteId.str}  rssi ${r.rssi}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openResult(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

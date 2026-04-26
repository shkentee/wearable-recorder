import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_ble_scanner.dart';
import 'device_page.dart';

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

  @override
  void initState() {
    super.initState();
    _sub = _scanner.results.listen(
      (rs) => setState(() => _results = rs),
      onError: (e) => setState(() => _error = e.toString()),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _error = null);
    final ok = await _ensurePermissions();
    if (!ok) {
      setState(() => _error = 'Bluetooth/location permission denied');
      return;
    }
    try {
      await _scanner.start();
    } catch (e) {
      setState(() => _error = 'scan failed: $e');
    }
  }

  Future<bool> _ensurePermissions() async {
    final perms = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return perms.values.every((s) => s.isGranted || s.isLimited);
  }

  void _open(ScanResult r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DevicePage(device: WrBleDevice(r.device)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('wearable-recorder'),
        actions: [
          IconButton(
            icon: Icon(_scanner.isScanning ? Icons.stop : Icons.search),
            onPressed: _scan,
            tooltip: 'Scan',
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
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('Tap search to scan'))
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
                        subtitle: Text('${r.device.remoteId.str}  rssi ${r.rssi}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

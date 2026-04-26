import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/wr_ble_device.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.device});
  final WrBleDevice device;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  String _status = 'connecting…';
  int _packets = 0;
  int _savedBytes = 0;

  @override
  void initState() {
    super.initState();
    widget.device.state.listen((s) {
      if (!mounted) return;
      setState(() => _status = s.name);
    });
    widget.device.packetCount.listen((n) {
      if (!mounted) return;
      setState(() => _packets = n);
    });
    widget.device.bytesSaved.listen((n) {
      if (!mounted) return;
      setState(() => _savedBytes = n);
    });
    _connect();
  }

  Future<void> _connect() async {
    try {
      await widget.device.connect();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error: $e');
    }
  }

  @override
  void dispose() {
    widget.device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.device.name)),
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
            const Spacer(),
            const Text(
              'Phase 6 MVP: notify subscription + raw dump. Opus decode '
              'runs offline on a paired PC.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
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

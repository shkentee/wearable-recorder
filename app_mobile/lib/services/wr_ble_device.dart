import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'wr_uuids.dart';

/// Single-connection GATT session against a wearable-recorder device.
///
/// Connects, discovers services, finds the audioCodec characteristic,
/// and counts notify packets. The actual decode + persist pipeline is
/// out of scope for the Phase 6 skeleton — we just need to prove that
/// the radio link works and notifications arrive.
class WrBleDevice {
  WrBleDevice(this._device);

  final BluetoothDevice _device;

  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  final _packetCount = StreamController<int>.broadcast();
  int _count = 0;

  Stream<int> get packetCount => _packetCount.stream;
  Stream<BluetoothConnectionState> get state => _device.connectionState;

  String get name {
    final n = _device.platformName;
    return n.isEmpty ? WrUuids.defaultDeviceName : n;
  }

  String get id => _device.remoteId.str;

  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    await _device.connect(timeout: timeout, autoConnect: false);
    final services = await _device.discoverServices();
    final audio = services.firstWhere(
      (s) => s.serviceUuid == Guid(WrUuids.audioService),
      orElse: () =>
          throw StateError('audio service ${WrUuids.audioService} not found'),
    );
    final codec = audio.characteristics.firstWhere(
      (c) => c.characteristicUuid == Guid(WrUuids.audioCodec),
      orElse: () =>
          throw StateError('audioCodec ${WrUuids.audioCodec} not found'),
    );
    await codec.setNotifyValue(true);
    _notifySub = codec.lastValueStream.listen(_onPacket);
  }

  void _onPacket(List<int> bytes) {
    if (bytes.isEmpty) return;
    _count++;
    _packetCount.add(_count);
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    if (_device.isConnected) {
      await _device.disconnect();
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _packetCount.close();
  }
}

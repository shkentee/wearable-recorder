import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'wr_audio_packet.dart';
import 'wr_packet_sink.dart';
import 'wr_storage_client.dart';
import 'wr_uuids.dart';

/// Single-connection GATT session against a wearable-recorder device.
///
/// Connects, discovers services, finds the audioCodec characteristic,
/// counts notify packets, and dumps each notify (header + payload) to
/// an append-only file under the application documents directory. The
/// dump is consumed by PC-side tooling for offline Opus decode; this
/// client deliberately avoids running Opus in-app.
class WrBleDevice {
  WrBleDevice(this._device, {WrPacketSink? sink}) : _injectedSink = sink;

  final BluetoothDevice _device;
  final WrPacketSink? _injectedSink;

  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  List<BluetoothService>? _discoveredServices;

  final _packetCount = StreamController<int>.broadcast();
  final _bytesSaved = StreamController<int>.broadcast();
  int _count = 0;

  WrPacketSink? _sink;

  Stream<int> get packetCount => _packetCount.stream;
  Stream<int> get bytesSaved => _bytesSaved.stream;
  Stream<BluetoothConnectionState> get state => _device.connectionState;

  String get name {
    final n = _device.platformName;
    return n.isEmpty ? WrUuids.defaultDeviceName : n;
  }

  String get id => _device.remoteId.str;

  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    await _device.connect(timeout: timeout, autoConnect: false);
    final services = await _device.discoverServices();
    _discoveredServices = services;
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
    _sink = _injectedSink ?? await _defaultSink();
    await codec.setNotifyValue(true);
    _notifySub = codec.lastValueStream.listen(_onPacket);
    // D7: send current epoch so firmware uses wall-clock filenames.
    await _trySendTimeSync(services);
  }

  /// Writes the current Unix epoch (seconds) to the D7 time-sync characteristic.
  ///
  /// Best-effort: silently skips if the firmware doesn't expose the time-sync
  /// service (bare omi builds, old firmware).
  Future<void> _trySendTimeSync(List<BluetoothService> services) async {
    try {
      final svc = services.firstWhere(
        (s) => s.serviceUuid == Guid(WrUuids.timeSyncService),
      );
      final char = svc.characteristics.firstWhere(
        (c) => c.characteristicUuid == Guid(WrUuids.timeSyncChar),
      );
      final epochSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await char.write(epochToBytes(epochSecs), withoutResponse: true);
    } catch (_) {
      // Old firmware or service not present — continue without time-sync.
    }
  }

  /// Encodes [epochSecs] as a little-endian 8-byte list (LE64).
  ///
  /// Exposed as a static for unit-testing. The firmware's `wr_time_sync_write()`
  /// expects exactly 8 bytes in little-endian order.
  static List<int> epochToBytes(int epochSecs) {
    final bytes = List<int>.filled(8, 0);
    var v = epochSecs;
    for (var i = 0; i < 8; i++) {
      bytes[i] = v & 0xff;
      v >>= 8;
    }
    return bytes;
  }

  Future<WrPacketSink> _defaultSink() async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final file = File('${dir.path}/wr_dumps/$id-$stamp.bin');
    return WrPacketSink(file);
  }

  void _onPacket(List<int> bytes) {
    if (bytes.isEmpty) return;
    // Validate header by attempting a parse — surfaces malformed
    // notifies in the count stream as a debugging aid. We don't keep
    // the parsed payload around; the sink stores raw bytes for PC-side
    // tooling.
    try {
      WrAudioPacket.parse(bytes);
    } on ArgumentError {
      return; // drop malformed packet, don't count it
    }
    _count++;
    _packetCount.add(_count);
    final sink = _sink;
    if (sink != null) {
      sink.add(bytes).then((_) => _bytesSaved.add(sink.bytesWritten));
    }
  }

  /// Opens a [WrStorageSession] against the device's storage GATT service.
  ///
  /// Returns null if the firmware does not expose the storage service (e.g.
  /// plain omi builds). Must be called after [connect].
  Future<WrStorageSession?> openStorageSession() async {
    final svcs = _discoveredServices;
    if (svcs == null) return null;
    return WrStorageSession.fromServices(svcs);
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    await _sink?.close();
    _sink = null;
    if (_device.isConnected) {
      await _device.disconnect();
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _packetCount.close();
    await _bytesSaved.close();
  }
}

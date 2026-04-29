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
  final _lostPackets = StreamController<int>.broadcast();
  final _batteryLevel = StreamController<int>.broadcast();
  StreamSubscription<List<int>>? _batterySub;
  int _count = 0;
  int _lostCount = 0;
  int? _lastPacketId; // null until at least one valid packet has arrived

  WrPacketSink? _sink;

  Stream<int> get packetCount => _packetCount.stream;
  Stream<int> get bytesSaved => _bytesSaved.stream;

  /// Cumulative count of dropped packets inferred from gaps in [packetId].
  /// A uint16 rollover (0xFFFF → 0x0000) is treated as a gap of 1 (the next
  /// expected value) and does NOT count as a loss.
  Stream<int> get lostPackets => _lostPackets.stream;

  /// Battery level in percent (0–100) from the BT Battery Service (0x180F).
  /// Emits on connect (initial READ) and whenever the firmware notifies.
  /// No-op if the firmware does not expose the Battery Service.
  Stream<int> get batteryLevel => _batteryLevel.stream;
  Stream<BluetoothConnectionState> get state => _device.connectionState;

  String get name {
    final n = _device.platformName;
    return n.isEmpty ? WrUuids.defaultDeviceName : n;
  }

  String get id => _device.remoteId.str;

  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    // autoConnect: true on Android avoids the GATT_ERROR (0x85 / 133) that
    // otherwise hits first-time connections to never-bonded peripherals.
    // It queues the connection at the OS level and retries until cancel,
    // which is more tolerant of address-type / param mismatches than the
    // direct-connect path.
    await _device.connect(timeout: timeout, autoConnect: true);
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
    // Battery Service: subscribe for level updates (best-effort).
    await _trySubscribeBattery(services);
  }

  /// Subscribes to the BT Battery Service (0x180F) if the firmware exposes it.
  /// Reads the initial value, then listens for NOTIFY updates.
  Future<void> _trySubscribeBattery(List<BluetoothService> services) async {
    try {
      final svc = services.firstWhere(
        (s) => s.serviceUuid == Guid(WrUuids.batteryService),
      );
      final char = svc.characteristics.firstWhere(
        (c) => c.characteristicUuid == Guid(WrUuids.batteryLevel),
      );
      // Initial read so the UI shows a value immediately.
      final raw = await char.read();
      if (raw.isNotEmpty) _batteryLevel.add(raw[0].clamp(0, 100));
      // Subscribe for incremental updates (firmware notifies every 60 s).
      if (char.properties.notify) {
        await char.setNotifyValue(true);
        _batterySub = char.lastValueStream.listen((raw) {
          if (raw.isNotEmpty) _batteryLevel.add(raw[0].clamp(0, 100));
        });
      }
    } catch (_) {
      // Firmware without Battery Service (plain omi builds) — continue.
    }
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
    final WrAudioPacket packet;
    try {
      packet = WrAudioPacket.parse(bytes);
    } on ArgumentError {
      return; // drop malformed packet, don't count it
    }

    // Packet-loss detection: compare against the previous packet id.
    // The id is a uint16 that wraps from 0xFFFF back to 0x0000.
    final prev = _lastPacketId;
    if (prev != null) {
      final expected = (prev + 1) & 0xFFFF;
      if (packet.packetId != expected) {
        // Compute gap, accounting for wrap-around.
        final gap = (packet.packetId - expected) & 0xFFFF;
        _lostCount += gap;
        _lostPackets.add(_lostCount);
      }
    }
    _lastPacketId = packet.packetId;

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
    await _batterySub?.cancel();
    _batterySub = null;
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
    await _lostPackets.close();
    await _batteryLevel.close();
  }
}

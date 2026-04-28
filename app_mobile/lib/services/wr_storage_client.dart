import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'wr_uuids.dart';

// Protocol byte constants (mirror of wr_storage_service.c)
const _cmdList = 0x00;
const _cmdFetch = 0x01;
const _cmdAbort = 0xFF;

const _notifFileEntry = 0x01;
const _notifData = 0x02;
const _notifEnd = 0x03;
const _notifError = 0xFF;

/// BLE client for the wearable-recorder Storage GATT service.
///
/// Wraps the storageStream (notify) and storageReadControl (write) GATT
/// characteristics to provide a typed async API for listing and fetching
/// files stored on the device's SD card.
///
/// Obtain an instance via [WrStorageSession.fromServices] (passing the
/// services discovered by [WrBleDevice.connect]) or via the test
/// constructor [WrStorageSession.forTest].
///
/// Every operation subscribes to [BluetoothCharacteristic.onValueReceived]
/// (not `lastValueStream`) to avoid receiving stale cached notifications
/// from a previous operation.
class WrStorageSession {
  WrStorageSession._({
    required BluetoothCharacteristic stream,
    required BluetoothCharacteristic ctrl,
  })  : _stream = stream,
        _ctrl = ctrl;

  /// Test-only constructor — injects characteristic mocks directly.
  WrStorageSession.forTest({
    required BluetoothCharacteristic stream,
    required BluetoothCharacteristic ctrl,
  })  : _stream = stream,
        _ctrl = ctrl;

  final BluetoothCharacteristic _stream;
  final BluetoothCharacteristic _ctrl;

  StreamSubscription<List<int>>? _sub;

  // -------------------------------------------------------------------
  // Factory
  // -------------------------------------------------------------------

  /// Creates a [WrStorageSession] from an already-discovered service list.
  ///
  /// Returns null if the storage service is absent (old / plain-omi firmware).
  static Future<WrStorageSession?> fromServices(
      List<BluetoothService> services) async {
    BluetoothService svc;
    try {
      svc = services.firstWhere(
        (s) => s.serviceUuid == Guid(WrUuids.storageService),
      );
    } catch (_) {
      return null;
    }

    final streamChar = svc.characteristics.firstWhere(
      (c) => c.characteristicUuid == Guid(WrUuids.storageStream),
    );
    final ctrlChar = svc.characteristics.firstWhere(
      (c) => c.characteristicUuid == Guid(WrUuids.storageReadControl),
    );

    await streamChar.setNotifyValue(true);
    return WrStorageSession._(stream: streamChar, ctrl: ctrlChar);
  }

  // -------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------

  /// Lists all completed `.opus` files on the device SD card.
  ///
  /// Sends a LIST command and collects [_notifFileEntry] notifications
  /// until an [_notifEnd] or [_notifError] is received.
  /// Throws [StateError] on device-side error.
  /// Throws [TimeoutException] if no END is received within [timeout].
  Future<List<String>> listFiles({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final files = <String>[];
    final completer = Completer<void>();

    _sub?.cancel();
    _sub = _stream.onValueReceived.listen((data) {
      if (data.isEmpty) return;
      switch (data[0]) {
        case _notifFileEntry:
          if (data.length > 1) {
            files.add(String.fromCharCodes(data.sublist(1)));
          }
        case _notifEnd:
          if (!completer.isCompleted) completer.complete();
        case _notifError:
          if (!completer.isCompleted) {
            completer.completeError(
                StateError('Storage service error during LIST'));
          }
      }
    });

    await _ctrl.write([_cmdList], withoutResponse: true);
    await completer.future.timeout(timeout);
    return files;
  }

  /// Fetches the named file from the device SD card and returns its bytes.
  ///
  /// Sends a FETCH command and collects [_notifData] chunks until
  /// [_notifEnd]. Throws [StateError] if the device reports an error
  /// (e.g. file not found). Throws [TimeoutException] if the transfer
  /// stalls for longer than [timeout].
  Future<Uint8List> fetchFile(
    String filename, {
    Duration timeout = const Duration(minutes: 5),
    void Function(int bytes)? onProgress,
  }) async {
    final chunks = <List<int>>[];
    int totalBytes = 0;
    final completer = Completer<void>();

    _sub?.cancel();
    _sub = _stream.onValueReceived.listen((data) {
      if (data.isEmpty) return;
      switch (data[0]) {
        case _notifData:
          if (data.length > 1) {
            final payload = data.sublist(1);
            chunks.add(payload);
            totalBytes += payload.length;
            onProgress?.call(totalBytes);
          }
        case _notifEnd:
          if (!completer.isCompleted) completer.complete();
        case _notifError:
          if (!completer.isCompleted) {
            completer.completeError(
                StateError('File not found on device: $filename'));
          }
      }
    });

    await _ctrl.write([_cmdFetch, ...filename.codeUnits],
        withoutResponse: true);
    await completer.future.timeout(timeout);

    // Concatenate chunks into a single Uint8List.
    final result = Uint8List(totalBytes);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  /// Sends an ABORT command and cancels the current subscription.
  Future<void> abort() async {
    await _ctrl.write([_cmdAbort], withoutResponse: true);
    _sub?.cancel();
    _sub = null;
  }

  /// Aborts any ongoing transfer and unsubscribes from notifications.
  Future<void> close() async {
    _sub?.cancel();
    _sub = null;
    try {
      await _ctrl.write([_cmdAbort], withoutResponse: true);
      await _stream.setNotifyValue(false);
    } catch (_) {
      // Best-effort on disconnect.
    }
  }
}

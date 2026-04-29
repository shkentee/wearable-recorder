import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'wr_uuids.dart';

/// Thin wrapper around FlutterBluePlus that scans for wearable-recorder
/// devices and filters results by device name on the Dart side.
///
/// Android's OS-level withServices filter only matches UUIDs in the main
/// advertisement packet, not the scan response. Since omi firmware places
/// the audio service UUID in the scan response, OS-level filtering misses
/// the device on Android. We scan without a UUID filter and drop results
/// that don't look like omi devices instead.
class WrBleScanner {
  static const Duration defaultTimeout = Duration(seconds: 12);

  StreamSubscription<List<ScanResult>>? _subscription;
  final _resultsController = StreamController<List<ScanResult>>.broadcast();

  Stream<List<ScanResult>> get results => _resultsController.stream;

  bool get isScanning => FlutterBluePlus.isScanningNow;

  Future<void> start({Duration timeout = defaultTimeout}) async {
    if (FlutterBluePlus.isScanningNow) {
      return;
    }
    _subscription?.cancel();
    _subscription = FlutterBluePlus.scanResults.listen(
      (rs) {
        final filtered = rs.where((r) {
          final name = r.device.platformName;
          return name == WrUuids.defaultDeviceName || name.startsWith('Omi');
        }).toList();
        _resultsController.add(filtered);
      },
      onError: (e) => _resultsController.addError(e),
    );
    await FlutterBluePlus.startScan(timeout: timeout);
  }

  Future<void> stop() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _resultsController.close();
  }
}

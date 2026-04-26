import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'wr_uuids.dart';

/// Thin wrapper around FlutterBluePlus that scans only for advertisers
/// exposing the omi audio service. Filtering by UUID at the OS level
/// keeps power use down and avoids enumerating every nearby BLE device.
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
      (rs) => _resultsController.add(rs),
      onError: (e) => _resultsController.addError(e),
    );
    await FlutterBluePlus.startScan(
      withServices: [Guid(WrUuids.audioService)],
      timeout: timeout,
    );
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

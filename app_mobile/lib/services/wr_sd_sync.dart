import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'wr_ble_device.dart';
import 'wr_drive_uploader.dart';
import 'wr_storage_client.dart';

/// Periodically pulls completed recording chunks off the device's SD card and
/// uploads them to Drive — the reliable, near-real-time path for the
/// transcription pipeline.
///
/// The device records to SD in ~10-minute chunks (firmware rotation) and the
/// storage service excludes the file that's currently being written, so every
/// file [listFiles] returns is complete and safe to fetch. We fetch any chunk
/// we haven't uploaded yet and push it to Drive (deduped by name + size). This
/// is loss-tolerant: the SD card is the source of truth, so a dropped BLE link
/// or a phone hiccup just delays a chunk — it's caught on the next pass.
class WrSdSync {
  WrSdSync({required this.device, required this.uploader});

  final WrBleDevice device;
  final WrDriveUploader uploader;

  Timer? _timer;
  bool _busy = false;
  WrStorageSession? _session;
  int uploadedCount = 0;

  final _events = StreamController<String>.broadcast();

  /// Human-readable progress messages ("uploaded <name>", "sync error: …").
  Stream<String> get events => _events.stream;

  void start({Duration interval = const Duration(seconds: 90)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
    _tick(); // run one pass immediately
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _session?.close();
    _session = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      _session ??= await device.openStorageSession();
      final session = _session;
      if (session == null) return; // firmware without storage service

      final files = await session.listFiles(); // completed files only
      for (final name in files) {
        if (await uploader.isUploadedByName(name)) continue;

        _events.add('fetching $name…');
        final bytes = await session.fetchFile(name);

        final dir = await getTemporaryDirectory();
        final tmp = File('${dir.path}/$name');
        await tmp.writeAsBytes(bytes);
        try {
          final id = await uploader.uploadIfNew(tmp, name);
          if (id != null) {
            uploadedCount++;
            _events.add('uploaded $name');
          }
        } finally {
          if (await tmp.exists()) {
            await tmp.delete();
          }
        }
      }
    } catch (e) {
      // Reset the session so the next pass reconnects cleanly, and retry later.
      await _session?.close();
      _session = null;
      if (!_events.isClosed) _events.add('sync error: $e');
    } finally {
      _busy = false;
    }
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wr_ble_device.dart';
import 'wr_drive_uploader.dart';
import 'wr_storage_client.dart';

/// Pulls the device's single growing recording file off the SD card
/// incrementally (omi-style) and re-emits it as discrete, complete,
/// epoch-named `.opus_sd` chunk files on Drive — the format the
/// voice_transcribe watcher expects (size-stable, name+size idempotent,
/// session-combined, moved after processing).
///
/// Why not upload one growing file? The Drive-for-desktop mirror re-downloads
/// a changed file whole (no append), the transcriber's size-stable wait never
/// fires on a growing file, and its name+size dedup would reprocess it every
/// update. So the phone acts like omi's backend: it slices the byte stream at
/// Opus frame boundaries into fixed-duration chunks and uploads each once.
///
/// Per device session file we keep a cursor: how many bytes we've fetched
/// (`offset`), bytes pending in the current chunk, and the next chunk index.
/// Chunk k starts at sessionStartEpoch + k*chunkSeconds, named
/// `<startEpoch>.opus_sd`. Deterministic boundaries make re-runs idempotent
/// (uploadIfNew dedups by name+size).
class WrSdSync {
  WrSdSync({
    required this.device,
    required this.uploader,
    this.chunkSeconds = 300, // 5-minute chunks
  });

  final WrBleDevice device;
  final WrDriveUploader uploader;
  final int chunkSeconds;

  static const int _window = 64 * 1024; // reliable per-fetch window
  static const int _maxBytesPerTick = 4 * 1024 * 1024;
  static const int _frameMs = 10; // one [len][frame] record = 10 ms of audio

  int get _framesPerChunk => chunkSeconds * 1000 ~/ _frameMs;

  Timer? _timer;
  bool _busy = false;
  WrStorageSession? _session;
  int uploadedChunks = 0;

  // Per-current-file cursor state.
  String? _name;
  int _offset = 0; // bytes fetched from the device file
  int _chunkIndex = 0; // next chunk number
  int? _sessionStartEpoch; // parsed from <epoch>.opus_sd, else null
  BytesBuilder _pending = BytesBuilder(copy: false);

  final _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;

  void start({Duration interval = const Duration(seconds: 30)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
    _tick();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    try {
      // Flush the trailing partial chunk so the tail isn't lost.
      if (_name != null) {
        await _flushPending(force: true);
        await _persist();
      }
    } catch (_) {}
    await _session?.close();
    _session = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  // ---- persistence (survive app restart / reconnect) --------------------

  Future<File> _pendingFile(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/pending_$name.bin');
  }

  int? _epochFromName(String name) {
    final m = RegExp(r'^(\d{10})\.opus_sd$').firstMatch(name);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  Future<void> _loadState(String name) async {
    final prefs = await SharedPreferences.getInstance();
    _name = name;
    _offset = prefs.getInt('wr_sync_off_$name') ?? 0;
    _chunkIndex = prefs.getInt('wr_sync_ci_$name') ?? 0;
    _sessionStartEpoch = _epochFromName(name);
    final pf = await _pendingFile(name);
    _pending = BytesBuilder(copy: false);
    if (await pf.exists()) {
      _pending.add(await pf.readAsBytes());
    }
  }

  Future<void> _persist() async {
    final name = _name;
    if (name == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('wr_sync_off_$name', _offset);
    await prefs.setInt('wr_sync_ci_$name', _chunkIndex);
    final pf = await _pendingFile(name);
    await pf.writeAsBytes(_pending.toBytes(), flush: true);
  }

  // ---- chunk cutting ----------------------------------------------------

  /// Byte length of the first [_framesPerChunk] whole [len][frame] records in
  /// [buf], or -1 if there aren't that many complete frames yet.
  int _chunkBoundary(Uint8List buf) {
    int pos = 0;
    int frames = 0;
    while (frames < _framesPerChunk) {
      if (pos >= buf.length) return -1; // need more
      final len = buf[pos];
      final next = pos + 1 + len;
      if (next > buf.length) return -1; // trailing partial frame
      pos = next;
      frames++;
    }
    return pos;
  }

  String _chunkName(int index) {
    final base = _sessionStartEpoch;
    if (base != null) {
      return '${base + index * chunkSeconds}.opus_sd';
    }
    // rec_NNNN (pre time-sync): approximate start from the phone clock.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '${now - chunkSeconds}.opus_sd';
  }

  Future<void> _emitChunk(Uint8List bytes) async {
    final name = _chunkName(_chunkIndex);
    final dir = await getTemporaryDirectory();
    final tmp = File('${dir.path}/$name');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      final id = await uploader.uploadIfNew(tmp, name);
      _chunkIndex++;
      if (id != null) {
        uploadedChunks++;
        _events.add('uploaded $name (${bytes.length}B)');
      }
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  /// Cuts and uploads every full chunk in [_pending]. With [force], also emits
  /// a final shorter chunk for the remaining bytes (session end). Returns true
  /// if any chunk was emitted (so the caller can checkpoint promptly).
  Future<bool> _flushPending({bool force = false}) async {
    var buf = _pending.toBytes();
    var changed = false;
    while (true) {
      final boundary = _chunkBoundary(buf);
      if (boundary < 0) break;
      await _emitChunk(Uint8List.sublistView(buf, 0, boundary));
      buf = Uint8List.sublistView(buf, boundary);
      changed = true;
    }
    if (force && buf.isNotEmpty) {
      await _emitChunk(buf);
      buf = Uint8List(0);
      changed = true;
    }
    if (changed) {
      _pending = BytesBuilder(copy: false)..add(buf);
    }
    return changed;
  }

  // ---- main loop --------------------------------------------------------

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      _session ??= await device.openStorageSession();
      final session = _session;
      if (session == null) return;

      final st = await session.status();
      if (st == null) return; // not recording / old firmware

      final name = st.name;
      final committed = st.size;

      if (name != _name) {
        // Switched session file — flush the previous one's tail, then load.
        if (_name != null) {
          await _flushPending(force: true);
          await _persist();
        }
        await _loadState(name);
      }

      if (_offset > committed) {
        // Device file shrank (reboot/new file reusing a name): restart it.
        _offset = 0;
        _chunkIndex = 0;
        _pending = BytesBuilder(copy: false);
      }

      int pulled = 0;
      int windows = 0;
      while (_offset < committed && pulled < _maxBytesPerTick) {
        final res = await session.fetchWindow(name, _offset, _window);
        if (res.bytes.isEmpty) break;
        _pending.add(res.bytes);
        _offset += res.bytes.length;
        pulled += res.bytes.length;
        windows++;
        // Cut + upload any complete chunks AS data arrives so a backlog
        // streams out instead of buffering MBs first. Checkpoint after a cut
        // or every 8 windows — persisting the (up to chunk-sized) pending
        // buffer every single window throttled throughput below real-time.
        final cut = await _flushPending();
        if (cut || (windows % 8) == 0) await _persist();
      }
      await _persist();

      if (pulled > 0) {
        _events.add('synced +${pulled}B of $name @$_offset/$committed');
      }
    } catch (e) {
      await _session?.close();
      _session = null;
      if (!_events.isClosed) _events.add('sync error: $e');
    } finally {
      _busy = false;
    }
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wr_ble_device.dart';
import 'wr_drive_uploader.dart';
import 'wr_storage_client.dart';
import 'wr_sync_schedule.dart';

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
/// Live progress of the incremental SD->Drive sync, for the UI.
class WrSyncProgress {
  const WrSyncProgress({
    required this.fileName,
    required this.committed,
    required this.synced,
    required this.bytesPerSec,
    required this.uploadedChunks,
    this.fetching = false,
  });

  final String? fileName; // device file being synced (null until first status)
  final int committed; // device file's committed size (bytes)
  final int synced; // bytes pulled to the phone so far
  final double bytesPerSec; // recent fetch throughput
  final int uploadedChunks; // chunks uploaded to Drive this session
  final bool fetching; // true while actively pulling a window right now

  /// Un-fetched bytes still on the device (the backlog).
  int get backlogBytes {
    final b = committed - synced;
    return b > 0 ? b : 0;
  }

  bool get caughtUp => backlogBytes == 0;
}

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
  // Bytes pulled before yielding to the other file (current <-> closed backlog).
  // Kept ~1 MB so the live file and the old-file backlog interleave every
  // ~1-2 min at BLE speed instead of one starving the other for many minutes.
  static const int _maxBytesPerPass = 1 * 1024 * 1024;
  static const int _frameMs = 10; // one [len][frame] record = 10 ms of audio

  int get _framesPerChunk => chunkSeconds * 1000 ~/ _frameMs;

  bool _running = false;
  Duration _idlePoll = const Duration(seconds: 10);
  WrStorageSession? _session;
  int uploadedChunks = 0;

  // Auto-pull schedule (loaded from prefs when the loop starts).
  SyncSchedule _schedule = const SyncSchedule();
  DateTime? _lastScheduledDate; // scheduledTime: last day a run completed
  DateTime? _lastIntervalRun; // intervalWindow: last completion time

  // Closed files that errored mid-fetch (e.g. SD bad sector -> fs_read -5).
  // Skipped for the rest of this session so one unreadable file can't block the
  // whole backlog; cleared on restart so a transient error gets retried.
  final Set<String> _failedFiles = {};

  /// Latest committed size the device reported for the current file.
  int lastCommitted = 0;

  // Recent-throughput tracking (for the UI rate read-out).
  int _rateRefOffset = 0;
  DateTime _rateRefTime = DateTime.now();
  double _bytesPerSec = 0;

  // Per-current-file cursor state.
  String? _name;
  int _offset = 0; // bytes fetched from the device file
  int _chunkIndex = 0; // next chunk number
  int? _sessionStartEpoch; // parsed from <epoch>.opus_sd, else null
  BytesBuilder _pending = BytesBuilder(copy: false);

  final _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;

  final _progress = StreamController<WrSyncProgress>.broadcast();
  Stream<WrSyncProgress> get progress => _progress.stream;

  void _emitProgress({bool fetching = false}) {
    if (_progress.isClosed) return;
    _progress.add(WrSyncProgress(
      fileName: _name,
      committed: lastCommitted,
      synced: _offset,
      bytesPerSec: _bytesPerSec,
      uploadedChunks: uploadedChunks,
      fetching: fetching,
    ));
  }

  /// Starts the continuous catch-up loop. While the device file has un-fetched
  /// bytes the loop pulls back-to-back (no fixed gap) so a backlog drains as
  /// fast as the BLE link allows; once caught up it polls every [idlePoll].
  void start({Duration idlePoll = const Duration(seconds: 10)}) {
    if (_running) return;
    _idlePoll = idlePoll;
    _running = true;
    _loop();
  }

  Future<void> stop() async {
    _running = false;
    try {
      // Flush the trailing partial chunk so the tail isn't lost.
      if (_name != null) {
        await _flushPending(force: true);
        await _persistOffset();
        await _persistPending();
      }
    } catch (_) {}
    await _session?.close();
    _session = null;
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _progress.close();
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

  /// Cheap checkpoint of just the cursor ints — safe to call every window so a
  /// mid-pass error never loses (or re-fetches) progress.
  Future<void> _persistOffset() async {
    final name = _name;
    if (name == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('wr_sync_off_$name', _offset);
    await prefs.setInt('wr_sync_ci_$name', _chunkIndex);
  }

  /// Writes the pending (not-yet-cut) bytes to disk. Heavier (a file write of up
  /// to one chunk) so it's called on chunk cuts / every few windows, not always.
  Future<void> _persistPending() async {
    final name = _name;
    if (name == null) return;
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

  /// Continuous driver: drain back-to-back while a backlog remains, otherwise
  /// idle-poll. Runs for the whole connection (only [stop] ends it). A transient
  /// BLE error reopens the cheap storage session (no reconnect) and retries
  /// within seconds instead of stalling a fixed interval — the bug that let the
  /// device out-record the old 64 KB-per-30 s sync.
  Future<void> _loop() async {
    _schedule = await SyncSchedule.load();
    while (_running) {
      final now = DateTime.now();
      if (!_schedule.shouldStart(now,
          lastScheduledDate: _lastScheduledDate,
          lastIntervalRun: _lastIntervalRun)) {
        // Outside the configured schedule — re-check shortly.
        await Future<void>.delayed(const Duration(seconds: 20));
        continue;
      }

      // Drain the whole backlog (catch up), retrying transient errors so a
      // mid-drain hiccup doesn't abandon the accumulated bytes.
      int pulled = 0;
      try {
        // Alternate one pass of the live current file with one pass of the
        // closed-file backlog (old sessions / rec_*), so neither starves — the
        // oldest data drains in parallel with keeping the live file moving,
        // which is what "drain everything older than ~15 min" needs.
        pulled = await _drainOnce();
        pulled += await _drainClosedFiles();
      } catch (e) {
        if (!_events.isClosed) _events.add('sync error: $e');
        await _reopenSession();
        await Future<void>.delayed(const Duration(seconds: 2));
        continue; // retry without marking this run complete
      }

      // Record completion (gates the scheduled / interval modes).
      final done = DateTime.now();
      _lastScheduledDate = done;
      _lastIntervalRun = done;

      // While a backlog remains, loop promptly to keep draining; once fully
      // caught up, idle-poll. Timed modes just re-check their trigger.
      await Future<void>.delayed(_schedule.mode != SyncMode.continuous
          ? const Duration(seconds: 20)
          : (pulled > 0 ? const Duration(milliseconds: 200) : _idlePoll));
    }
  }

  Future<void> _reopenSession() async {
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
  }

  /// One drain pass: refresh status, then pull up to [_maxBytesPerPass] of the
  /// backlog in [_window] windows, cutting/uploading chunks as data arrives.
  /// Returns bytes pulled this pass (0 = caught up / nothing to do).
  Future<int> _drainOnce() async {
    _session ??= await device.openStorageSession();
    final session = _session;
    if (session == null) return 0; // no storage service (old firmware)

    final st = await session.status();
    if (st == null) {
      _emitProgress();
      return 0; // not recording / old firmware
    }

    final name = st.name;
    final committed = st.size;
    lastCommitted = committed;

    if (name != _name) {
      // Switched files — flush the previous one's COMPLETE chunks only (never
      // force a partial chunk on a switch: the file may still be growing or be
      // resumed later; partial tails are only flushed when a file is finished).
      if (_name != null) {
        await _flushPending();
        await _persistOffset();
        await _persistPending();
      }
      await _loadState(name);
      _rateRefOffset = _offset;
      _rateRefTime = DateTime.now();
    }

    if (_offset > committed) {
      // Device file shrank (reboot/new file reusing a name): restart it.
      _offset = 0;
      _chunkIndex = 0;
      _pending = BytesBuilder(copy: false);
    }

    if (_offset >= committed) {
      _bytesPerSec = 0;
      _emitProgress();
      return 0; // caught up
    }

    int pulled = 0;
    int windows = 0;
    while (_running && _offset < committed && pulled < _maxBytesPerPass) {
      final res = await session.fetchWindow(name, _offset, _window);
      if (res.bytes.isEmpty) break;
      _pending.add(res.bytes);
      _offset += res.bytes.length;
      pulled += res.bytes.length;
      windows++;

      // Throughput estimate over a ~2 s sliding reference (for the UI).
      final now = DateTime.now();
      final dt = now.difference(_rateRefTime).inMilliseconds;
      if (dt >= 2000) {
        _bytesPerSec = (_offset - _rateRefOffset) * 1000 / dt;
        _rateRefOffset = _offset;
        _rateRefTime = now;
      }

      // Persist the cursor every window (cheap) so a mid-pass error can't lose
      // or re-fetch progress; cut + upload complete chunks as they form.
      await _persistOffset();
      final cut = await _flushPending();
      if (cut || (windows % 8) == 0) await _persistPending();
      _emitProgress(fetching: true);
    }
    await _persistOffset();
    await _persistPending();

    if (pulled > 0) {
      _events.add('synced +${pulled}B of $name @$_offset/$committed');
    }
    _emitProgress();
    return pulled;
  }

  /// Pull the backlog of CLOSED audio files (previous sessions, rec_*). Drains
  /// one pass of one not-yet-finished file per call, so the live current file
  /// keeps priority; a file is flagged done in prefs once fully fetched.
  Future<int> _drainClosedFiles() async {
    final session = _session;
    if (session == null) return 0;
    List<String> files;
    try {
      files = await session.listFiles();
    } catch (_) {
      return 0;
    }
    final prefs = await SharedPreferences.getInstance();
    for (final name in files) {
      if (!_running) break;
      if (!name.endsWith('.opus_sd')) continue;
      if (name.startsWith('battlog')) continue; // measurement instrument files
      if (_failedFiles.contains(name)) continue; // unreadable this session
      if (prefs.getBool('wr_sync_done_$name') ?? false) continue;
      return await _drainClosedFile(name);
    }
    return 0;
  }

  /// Drain one pass (<= [_maxBytesPerPass]) of a closed file, chunking +
  /// uploading like the current file. Marks it done once fully fetched.
  Future<int> _drainClosedFile(String name) async {
    final session = _session;
    if (session == null) return 0;

    if (name != _name) {
      if (_name != null) {
        await _flushPending();
        await _persistOffset();
        await _persistPending();
      }
      await _loadState(name);
      _rateRefOffset = _offset;
      _rateRefTime = DateTime.now();
    }

    int pulled = 0;
    int windows = 0;
    int committed = -1;
    try {
      while (_running && pulled < _maxBytesPerPass) {
        final res = await session.fetchWindow(name, _offset, _window);
        committed = res.committedSize;
        lastCommitted = committed;
        if (res.bytes.isEmpty) break;
        _pending.add(res.bytes);
        _offset += res.bytes.length;
        pulled += res.bytes.length;
        windows++;

        final now = DateTime.now();
        final dt = now.difference(_rateRefTime).inMilliseconds;
        if (dt >= 2000) {
          _bytesPerSec = (_offset - _rateRefOffset) * 1000 / dt;
          _rateRefOffset = _offset;
          _rateRefTime = now;
        }

        await _persistOffset();
        final cut = await _flushPending();
        if (cut || (windows % 8) == 0) await _persistPending();
        _emitProgress(fetching: true);
        if (_offset >= committed) break;
      }
    } catch (e) {
      // This file won't read past _offset (e.g. SD bad sector -> fs_read -5).
      // Skip it for the session so it can't block the rest of the backlog;
      // keep the bytes already pulled. Don't rethrow (avoid a tight retry loop).
      _failedFiles.add(name);
      await _persistOffset();
      await _persistPending();
      if (!_events.isClosed) _events.add('skip $name @$_offset (read error): $e');
      _emitProgress();
      return pulled;
    }

    // Fully fetched -> flush the final tail and mark done so it's skipped next.
    if (committed >= 0 && _offset >= committed) {
      await _flushPending(force: true);
      await _persistOffset();
      await _persistPending();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('wr_sync_done_$name', true);
    }
    _emitProgress();
    return pulled;
  }
}

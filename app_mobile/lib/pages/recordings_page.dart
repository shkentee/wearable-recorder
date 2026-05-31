import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../services/wr_drive_uploader.dart';
import '../services/wr_local_recordings.dart';
import '../services/wr_opus_decoder.dart';

/// Lists locally-saved recordings and plays them in-app by decoding the raw
/// Opus dump to a temporary WAV (16 kHz mono) and playing it with just_audio.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key, WrDriveUploader? uploader})
      : _uploaderOverride = uploader;

  final WrDriveUploader? _uploaderOverride;

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  final _player = AudioPlayer();
  WrDriveUploader get _uploader =>
      widget._uploaderOverride ?? WrDriveUploader();

  List<WrRecording> _recs = [];
  bool _loading = true;
  String? _playingPath; // dump path currently loaded into the player
  bool _isPlaying = false; // live play/pause state from the player
  double? _decodeProgress; // non-null while decoding
  final Set<String> _uploading = {};

  @override
  void initState() {
    super.initState();
    // Drive the UI from the player's own state stream so the play/pause icon
    // and the "now playing" highlight update the moment playback actually
    // starts, pauses, or finishes.
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        _player.stop();
        setState(() {
          _isPlaying = false;
          _playingPath = null;
        });
      } else {
        setState(() => _isPlaying = s.playing);
      }
    });
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final recs = await WrLocalRecordings.list();
    if (!mounted) return;
    setState(() {
      _recs = recs;
      _loading = false;
    });
  }

  String _remoteName(File f) => f.uri.pathSegments.last
      .replaceAll(':', '-')
      .replaceAll('.bin', '.opus');

  Future<void> _togglePlay(WrRecording rec) async {
    // Tapping the currently-loaded item toggles pause/resume.
    // NOTE: do NOT await play() — just_audio's play() future only completes
    // when playback *finishes*, so awaiting it would freeze the icon on ▶.
    if (_playingPath == rec.file.path) {
      if (_isPlaying) {
        await _player.pause();
      } else {
        unawaited(_player.play());
      }
      return; // icon/highlight update arrives via playerStateStream
    }

    await _player.stop();
    setState(() {
      _playingPath = rec.file.path;
      _isPlaying = false;
      _decodeProgress = 0;
    });
    try {
      final tmp = await getTemporaryDirectory();
      final wavPath = '${tmp.path}/play_${rec.name}.wav';
      await WrOpusDecoder.decodeDumpToWav(
        rec.file,
        wavPath,
        onProgress: (p) {
          if (mounted) setState(() => _decodeProgress = p);
        },
      );
      if (!mounted) return;
      setState(() => _decodeProgress = null);
      await _player.setFilePath(wavPath);
      unawaited(_player.play());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _decodeProgress = null;
        _playingPath = null;
        _isPlaying = false;
      });
      _snack('Playback failed: $e', error: true);
    }
  }

  Future<void> _upload(WrRecording rec) async {
    setState(() => _uploading.add(rec.file.path));
    try {
      final id =
          await _uploader.uploadIfNew(rec.file, _remoteName(rec.file));
      _snack(id == null
          ? 'Already uploaded.'
          : 'Uploaded to Drive (id: $id)');
    } catch (e) {
      _snack('Upload failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploading.remove(rec.file.path));
    }
  }

  Future<void> _delete(WrRecording rec) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(rec.name),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (_playingPath == rec.file.path) {
      await _player.stop();
      _playingPath = null;
    }
    await rec.file.delete();
    await _load();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s}s';
  }

  String _fmtSize(int b) => b >= 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';

  String _fmtTime(DateTime t) {
    String two(int x) => x.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _recs.isEmpty
              ? const Center(child: Text('No local recordings yet.'))
              : ListView.separated(
                  itemCount: _recs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _tile(_recs[i]),
                ),
    );
  }

  Widget _tile(WrRecording rec) {
    final theme = Theme.of(context);
    final isCurrent = _playingPath == rec.file.path;
    final decoding = isCurrent && _decodeProgress != null;
    final playing = isCurrent && _isPlaying && _decodeProgress == null;
    final paused = isCurrent && !_isPlaying && _decodeProgress == null;
    final busyUpload = _uploading.contains(rec.file.path);

    final accent = theme.colorScheme.primary;
    final status = decoding
        ? 'decoding ${(100 * (_decodeProgress ?? 0)).round()}%…'
        : playing
            ? '▶ playing'
            : paused
                ? '⏸ paused'
                : null;

    return ListTile(
      selected: isCurrent,
      selectedTileColor: accent.withOpacity(0.10),
      leading: IconButton(
        icon: decoding
            ? SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: (_decodeProgress ?? 0) > 0 ? _decodeProgress : null,
                ),
              )
            : Icon(
                playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                color: isCurrent ? accent : null,
              ),
        iconSize: 34,
        tooltip: playing ? 'Pause' : 'Play',
        onPressed: decoding ? null : () => _togglePlay(rec),
      ),
      title: Text(
        _fmtTime(rec.startedAt),
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        '${_fmtSize(rec.sizeBytes)} · ~${_fmtDur(rec.approxDuration)}'
        '${status != null ? '   ·   $status' : ''}',
        style: status != null
            ? TextStyle(color: accent, fontWeight: FontWeight.w500)
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          busyUpload
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: 'Upload to Drive',
                  onPressed: () => _upload(rec),
                ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: () => _delete(rec),
          ),
        ],
      ),
    );
  }
}

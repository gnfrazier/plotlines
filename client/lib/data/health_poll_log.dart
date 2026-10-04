import 'dart:convert';
import 'dart:io';

/// Issue #583 — the debug `/health` poll log (#232), bounded.
///
/// Two rules, both the sidecar log's own posture (`logging_setup.py`: 5 ×
/// 2 MB): a body identical to the last one written is not written again —
/// the next distinct line carries `unchanged_polls`, so a reader still sees
/// how long a state held — and a file past [maxBytes] rolls to `.1`, `.2`,
/// …, keeping [backupCount] old files. Before this the file only grew: the
/// owner's machine held 223 MB, and in #574's window 392 consecutive polls
/// were one identical `{"ready": true}`.
class HealthPollLog {
  HealthPollLog(this.path, {this.maxBytes = 2000000, this.backupCount = 5});

  final String path;
  final int maxBytes;
  final int backupCount;

  String? _lastBody;
  int _unchanged = 0;
  Future<void> _tail = Future.value();

  /// Append [body] (a `/health` response) unless it repeats the last one.
  /// Writes are chained, so an unawaited caller can't interleave a rotation
  /// with an append.
  Future<void> append(String body, {DateTime? now}) {
    if (body == _lastBody) {
      _unchanged++;
      return _tail;
    }
    _lastBody = body;
    final unchanged = _unchanged;
    _unchanged = 0;
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    return _tail = _tail
        .then((_) => _write(body, ts, unchanged))
        .catchError((Object _) {});
  }

  Future<void> _write(String body, String ts, int unchanged) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() >= maxBytes) {
      await _rotate();
    }
    final line = jsonEncode({
      'ts': ts,
      if (unchanged > 0) 'unchanged_polls': unchanged,
      'body': jsonDecode(body),
    });
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  Future<void> _rotate() async {
    final oldest = File('$path.$backupCount');
    if (await oldest.exists()) await oldest.delete();
    for (var i = backupCount - 1; i >= 1; i--) {
      final f = File('$path.$i');
      if (await f.exists()) await f.rename('$path.${i + 1}');
    }
    if (backupCount >= 1) {
      await File(path).rename('$path.1');
    } else {
      await File(path).delete();
    }
  }
}

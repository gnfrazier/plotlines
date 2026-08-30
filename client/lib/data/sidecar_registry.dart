import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// M12 — the next-launch orphan sweep (ARCH §7.3 / §8.4; SPIKE-00
/// `WINDOWS.md` §3).
///
/// The client records every sidecar it spawns to a small JSON file under the
/// app-support dir and deletes the record on a graceful stop. A record still
/// present at the next launch means the previous client process died — a
/// crash, `kill -9`, a power loss — without stopping its child, leaving a
/// sidecar holding a loopback port. [sweep] runs once at app start, before a
/// fresh sidecar is spawned, and terminates any survivor it can still
/// positively identify.
///
/// **This is the POSIX backstop.** On Windows the orphan backstop is the Job
/// Object in `SidecarProcess` (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`), which
/// the OS honours even when the client exits without running cleanup —
/// Windows has no process groups to sweep and never reparents, so a dead
/// parent PID proves nothing there. The registry file is still written on
/// Windows (harmless, one code path) but [sweep] is a no-op there.
///
/// **PID reuse is guarded structurally, not by luck.** A recorded PID may
/// have been recycled by the OS for an unrelated process by the next launch,
/// so a live PID alone is never sufficient to kill: [sweep] also probes the
/// recorded loopback port and only terminates the PID if something there
/// still answers `GET /health` as a Plotlines sidecar. A recycled PID whose
/// old port is dead or now owned by something else is left alone.
///
/// **A sweep only removes an entry it has resolved** (issue #183). An entry
/// is pruned when its process is confirmed dead, or when this sweep confirmed
/// it killed. An entry that is still alive but was *not* terminated — the
/// `/health` probe timed out mid-boot, or [_terminate] threw — is kept so the
/// next launch can try again, instead of being erased and leaked for the life
/// of the machine. Provisional retention is bounded by [_maxSweepAttempts]
/// and [_maxOrphanAge] so a permanently unidentifiable entry does not
/// accumulate forever.
class SidecarRegistry {
  /// After this many consecutive sweeps that could neither identify nor kill
  /// an entry, stop carrying it — it is almost certainly a recycled PID whose
  /// old port is now dead or foreign, not our slow-booting sidecar.
  static const _maxSweepAttempts = 10;

  /// A backstop on [_maxSweepAttempts] for the case where sweeps are rare:
  /// no app-spawned sidecar we still care about reaping is a week old.
  static const _maxOrphanAge = Duration(days: 7);

  SidecarRegistry(
    this.file, {
    bool Function(int pid)? isProcessAlive,
    Future<bool> Function(int port)? respondsAsSidecar,
    Future<void> Function(int pid)? terminate,
    bool? actOnThisPlatform,
  })  : _isProcessAlive = isProcessAlive ?? _defaultIsProcessAlive,
        _respondsAsSidecar = respondsAsSidecar ?? _defaultRespondsAsSidecar,
        _terminate = terminate ?? _defaultTerminate,
        _actOnThisPlatform = actOnThisPlatform ?? !Platform.isWindows;

  /// Where the registry is persisted. One entry per spawned sidecar.
  final File file;

  final bool Function(int pid) _isProcessAlive;
  final Future<bool> Function(int port) _respondsAsSidecar;
  final Future<void> Function(int pid) _terminate;
  final bool _actOnThisPlatform;

  /// Adds a spawned sidecar to the registry. Called right after the process
  /// is up and its PID is known.
  Future<void> record(int pid, int port) async {
    final entries = await _read();
    entries.removeWhere((e) => e.pid == pid);
    entries.add(_Entry(pid: pid, port: port, spawnedAt: DateTime.now().toUtc()));
    await _write(entries);
  }

  /// Removes a sidecar from the registry — the graceful-stop path, so a
  /// clean shutdown leaves nothing for the next launch to sweep. Idempotent:
  /// forgetting a PID that isn't recorded is a no-op.
  Future<void> forget(int pid) async {
    final entries = await _read();
    final before = entries.length;
    entries.removeWhere((e) => e.pid == pid);
    if (entries.length != before) await _write(entries);
  }

  /// Terminates any sidecar the previous client left running and rewrites the
  /// registry to hold only the entries this sweep could not resolve (issue
  /// #183). Returns the PIDs actually killed, for logging and tests.
  ///
  /// Safe to call unconditionally at startup: a missing or corrupt file, a
  /// Windows host, or an empty registry all resolve to "nothing to do"
  /// without throwing — an orphan sweep must never be the thing that stops
  /// the app from starting.
  Future<List<int>> sweep() async {
    if (!_actOnThisPlatform) return const [];

    final entries = await _read();
    if (entries.isEmpty) return const [];

    final now = DateTime.now().toUtc();
    final killed = <int>[];
    final retained = <_Entry>[];

    for (final entry in entries) {
      // Confirmed dead: the PID owns no process. Prune.
      if (!_isProcessAlive(entry.pid)) continue;

      if (!await _respondsAsSidecar(entry.port)) {
        // Alive, but nothing on the recorded port identifies as a Plotlines
        // sidecar within the probe window. Two cases collapse here and we
        // cannot tell them apart in one pass: a recycled PID whose old port
        // is dead or foreign (safe to drop), and our own sidecar still
        // mid-boot — cold start, a large pmtiles archive, a loaded machine —
        // which must NOT be dropped or it leaks forever. Retain provisionally
        // and let the attempt/age bound end it.
        _retainWithinBounds(entry, now, retained);
        continue;
      }

      try {
        await _terminate(entry.pid);
        killed.add(entry.pid); // confirmed killed — prune
      } catch (error) {
        debugPrint('sidecar: orphan sweep could not terminate ${entry.pid}: $error');
        _retainWithinBounds(entry, now, retained); // still alive — keep for a retry
      }
    }

    await _write(retained);
    return killed;
  }

  /// Carries [entry] forward to the next launch's sweep with its attempt
  /// count bumped — unless it has now exhausted [_maxSweepAttempts] or
  /// [_maxOrphanAge], at which point it is dropped with a log line rather
  /// than carried indefinitely.
  void _retainWithinBounds(_Entry entry, DateTime now, List<_Entry> retained) {
    final attempts = entry.sweepAttempts + 1;
    final age = now.difference(entry.spawnedAt);
    if (attempts >= _maxSweepAttempts || age >= _maxOrphanAge) {
      debugPrint('sidecar: giving up on unresolved orphan ${entry.pid} '
          '(port ${entry.port}) after $attempts sweeps / ${age.inHours}h — '
          'dropping from the registry');
      return;
    }
    retained.add(entry.withSweepAttempt(attempts));
  }

  Future<List<_Entry>> _read() async {
    try {
      if (!await file.exists()) return [];
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['entries'] is! List) return [];
      return [
        for (final item in raw['entries'] as List)
          if (item is Map<String, dynamic> && _Entry.isValid(item)) _Entry.fromJson(item),
      ];
    } catch (error) {
      debugPrint('sidecar: orphan registry unreadable ($error) — treating as empty');
      return [];
    }
  }

  Future<void> _write(List<_Entry> entries) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'entries': [for (final e in entries) e.toJson()]}),
      flush: true,
    );
  }

  static bool _defaultIsProcessAlive(int pid) {
    // SIGCONT is a no-op for a running process; `killPid` returns false when
    // no process owns the PID. This is the liveness probe `dart:io` gives us
    // without a raw signal-0.
    try {
      return Process.killPid(pid, ProcessSignal.sigcont);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultRespondsAsSidecar(int port) async {
    try {
      final resp = await http
          .get(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return false;
      final body = jsonDecode(resp.body);
      return body is Map && body['sidecar_version'] != null && body['capabilities'] is Map;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _defaultTerminate(int pid) async {
    Process.killPid(pid, ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

class _Entry {
  _Entry({
    required this.pid,
    required this.port,
    required this.spawnedAt,
    this.sweepAttempts = 0,
  });

  final int pid;
  final int port;
  final DateTime spawnedAt;

  /// How many prior sweeps carried this entry forward without resolving it
  /// (issue #183). Absent in registries written before this field existed —
  /// [fromJson] defaults it to 0.
  final int sweepAttempts;

  _Entry withSweepAttempt(int attempts) =>
      _Entry(pid: pid, port: port, spawnedAt: spawnedAt, sweepAttempts: attempts);

  static bool isValid(Map<String, dynamic> json) =>
      json['pid'] is int && json['port'] is int && json['spawned_at'] is String;

  factory _Entry.fromJson(Map<String, dynamic> json) => _Entry(
        pid: json['pid'] as int,
        port: json['port'] as int,
        spawnedAt: DateTime.parse(json['spawned_at'] as String),
        sweepAttempts: json['sweep_attempts'] is int ? json['sweep_attempts'] as int : 0,
      );

  Map<String, dynamic> toJson() => {
        'pid': pid,
        'port': port,
        'spawned_at': spawnedAt.toIso8601String(),
        'sweep_attempts': sweepAttempts,
      };
}

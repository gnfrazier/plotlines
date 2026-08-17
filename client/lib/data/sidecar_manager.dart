import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// M12 — spawn, health-poll to readiness, restart-once, graceful stop, orphan
/// sweep, paired-version refusal (ARCH §7.3, §12.1; PRD M12).
///
/// The eight desktop states in M13 include three that live here: "sidecar
/// starting", "sidecar won't start", "sidecar died mid-session".
enum SidecarState { starting, ready, restarting, failed, degraded, stopped }

class SidecarStatus {
  const SidecarStatus(this.state, {this.detail = '', this.port});
  final SidecarState state;
  final String detail;
  final int? port;
}

/// The client's own build version, read from `packaging/version.lock` (ARCH
/// §12.1, MVP doc §2.2) rather than hand-kept — a hand-kept constant is
/// exactly the "two artifacts quietly diverge" failure A8 exists to close,
/// and it already had (the constant sat at `0.0.1` while `version.lock` was
/// free to move). Flutter has no simple pre-build shell hook the way the
/// sidecar's freeze script does, so this reads the file at runtime instead
/// of stamping a generated constant at build time — the same repo-relative
/// dev-fallback resolution [SidecarManager] already uses for the binary and
/// cache dir, which means it can never itself drift from the file it reads.
/// Cached after the first successful read since the file cannot change
/// under a running process.
String? _cachedClientVersion;

String resolveClientVersion() {
  final cached = _cachedClientVersion;
  if (cached != null) return cached;

  final exeDir = File(Platform.resolvedExecutable).parent;
  final bundled = File('${exeDir.path}/version.lock');
  File? found = bundled.existsSync() ? bundled : null;

  if (found == null) {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final candidate = File('${dir.path}/packaging/version.lock');
      if (candidate.existsSync()) {
        found = candidate;
        break;
      }
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
  }
  if (found == null) {
    throw StateError('version.lock not found (dev or bundled)');
  }

  final version = found
      .readAsLinesSync()
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));
  _cachedClientVersion = version;
  return version;
}

class SidecarManager extends ChangeNotifier {
  SidecarManager({this.cacheDirOverride, this.binaryOverride});

  final Directory? cacheDirOverride;
  final String? binaryOverride;

  Process? _process;
  int? _port;
  String? _confirmedVersion;
  SidecarStatus _status = const SidecarStatus(SidecarState.starting);
  bool _restarted = false;
  bool _stoppingDeliberately = false;

  SidecarStatus get status => _status;
  int? get port => _port;
  String get baseUrl => 'http://127.0.0.1:${_port ?? 0}';

  /// The version the running sidecar reported at its last successful
  /// `--version` check (K10's About surface / M12's `/health` comparison).
  /// Null until a check has actually passed.
  String? get confirmedVersion => _confirmedVersion;

  void _set(SidecarState state, {String detail = ''}) {
    _status = SidecarStatus(state, detail: detail, port: _port);
    notifyListeners();
  }

  /// Locates the frozen sidecar binary. Production layout bundles it beside
  /// the app (ARCH §12.2); this also falls back to the repo-relative
  /// `packaging/dist` build for running from source during development.
  String _resolveBinaryPath() {
    final override = binaryOverride;
    if (override != null) return override;
    final exeDir = File(Platform.resolvedExecutable).parent;
    final bundled = Platform.isWindows
        ? File('${exeDir.path}/sidecar/plotlines-sidecar.exe')
        : File('${exeDir.path}/sidecar/plotlines-sidecar');
    if (bundled.existsSync()) return bundled.path;

    // Dev fallback: walk up from cwd looking for the monorepo's packaging/dist.
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final candidate = File(
          '${dir.path}/packaging/dist/pyinstaller-onedir/plotlines-sidecar/plotlines-sidecar');
      if (candidate.existsSync()) return candidate.path;
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    throw StateError('plotlines-sidecar binary not found (dev or bundled)');
  }

  Directory _resolveCacheDir() {
    final override = cacheDirOverride;
    if (override != null) return override;
    // Dev fallback: the Boulder fixture graph/DEM under spikes/SPIKE-00/cache
    // has the exact filenames app.py expects. The real region-download
    // pipeline (A10) that would populate the app-support cache dir for an
    // arbitrary Author-chosen location is not built yet (open question).
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final candidate = Directory('${dir.path}/spikes/SPIKE-00/cache');
      if (candidate.existsSync()) return candidate;
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    throw StateError('no sidecar cache-dir found (dev fallback missing)');
  }

  Future<int> _pickPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Runs `--version` against the resolved binary without spawning a server,
  /// so the A8 mismatch check can happen before anything else is committed.
  Future<String> readBinaryVersion() async {
    final result = await Process.run(_resolveBinaryPath(), ['--version']);
    return (result.stdout as String).trim();
  }

  Future<void> start() async {
    _set(SidecarState.starting, detail: 'checking sidecar version');
    final binPath = _resolveBinaryPath();

    final sidecarVersion = await readBinaryVersion();
    final clientVersion = resolveClientVersion();
    if (sidecarVersion != clientVersion) {
      // A8: never run the client against a mismatched sidecar.
      _set(SidecarState.failed,
          detail: 'version mismatch: client $clientVersion, '
              'sidecar $sidecarVersion');
      return;
    }
    _confirmedVersion = sidecarVersion;

    _port = await _pickPort();
    _set(SidecarState.starting, detail: 'launching sidecar');

    _process = await Process.start(binPath, [
      '--port=$_port',
      '--host=127.0.0.1',
      '--mode=sidecar',
      '--cache-dir=${_resolveCacheDir().path}',
    ]);
    _process!.exitCode.then(_onExit);

    await _pollUntilReady();
  }

  Future<void> _pollUntilReady() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      // Escalating honest wait message rather than a bare spinner (MVP §4).
      final waitDetail = attempt < 6
          ? 'starting up'
          : attempt < 15
              ? 'still loading the route graph — this can take a while on '
                  'first launch'
              : 'taking longer than expected — still working, not stuck';
      _set(SidecarState.starting, detail: waitDetail);
      try {
        final resp = await http
            .get(Uri.parse('$baseUrl/health'))
            .timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body) as Map<String, dynamic>;
          if (body['ready'] == true) {
            _set(SidecarState.ready, detail: 'ready');
            return;
          }
        }
      } catch (_) {
        // Not up yet — keep polling.
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    _set(SidecarState.failed, detail: 'health-check timeout');
  }

  void _onExit(int code) {
    if (_stoppingDeliberately) {
      _set(SidecarState.stopped, detail: 'stopped');
      return;
    }
    if (!_restarted) {
      _restarted = true;
      _set(SidecarState.restarting, detail: 'sidecar exited unexpectedly — restarting');
      start();
      return;
    }
    // Second failure: degrade honestly rather than loop (M13, M12).
    _set(SidecarState.degraded,
        detail: 'sidecar died twice — cached trips still viewable, '
            'generation unavailable');
  }

  /// Graceful stop. POSIX: SIGTERM, then SIGKILL after a grace period.
  /// Windows has no deliverable SIGTERM (TerminateProcess is an unblockable
  /// hard kill), so the real contract needs AttachConsole + a muted default
  /// Ctrl handler + CTRL_BREAK_EVENT (ARCH §7.3) — that sequence requires
  /// Win32 FFI calls not implemented here yet (open question; untestable on
  /// this Linux dev machine regardless). `taskkill` is the interim fallback.
  Future<void> stop() async {
    _stoppingDeliberately = true;
    final proc = _process;
    if (proc == null) return;
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/pid', '${proc.pid}', '/t', '/f']);
    } else {
      proc.kill(ProcessSignal.sigterm);
      final exited = await proc.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () => -1);
      if (exited == -1) proc.kill(ProcessSignal.sigkill);
    }
    _set(SidecarState.stopped, detail: 'stopped');
  }
}

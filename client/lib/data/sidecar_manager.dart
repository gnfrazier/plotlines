import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'sidecar_process.dart';

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

/// One capability's readiness, mirroring `/health`'s per-capability entry
/// (ARCH §8.3, PRD FR121). `progress`/`etaS` are only ever present while
/// [ready] is false and the capability is actively loading — a settled
/// capability (ready, or failed) carries neither.
class CapabilityStatus {
  const CapabilityStatus({required this.ready, this.reason, this.progress, this.etaS});

  final bool ready;
  final String? reason;
  final double? progress;
  final double? etaS;

  /// Stopped trying, one way or another — distinct from `!ready`, which is
  /// also true while still loading. Generalized from a `'failed:'`-prefix
  /// check (issue #154): a capability that will simply never load in this
  /// codebase (`elevation`, gated on #148) reports a fixed reason with no
  /// `progress`, which is exactly the same "stop waiting on this" signal a
  /// genuine failure gives — the absence of `progress` is what actually
  /// means "not actively loading" in every case `/health` produces. A
  /// disabled control reads this to decide between an honest wait and an
  /// honest "this isn't happening" (FR121: never silent).
  bool get failed => !ready && progress == null;

  factory CapabilityStatus.fromJson(Map<String, dynamic> json) => CapabilityStatus(
        ready: json['ready'] as bool? ?? false,
        reason: json['reason'] as String?,
        progress: (json['progress'] as num?)?.toDouble(),
        etaS: (json['eta_s'] as num?)?.toDouble(),
      );

  /// A human-readable, honest line for a disabled control — never a bare
  /// spinner (ARCH §8.3's "terrain data loading — routing available in
  /// about 3 minutes").
  String describe(String capabilityLabel) {
    if (ready) return '$capabilityLabel ready';
    final r = reason ?? 'not ready';
    if (etaS == null) return '$capabilityLabel unavailable — $r';
    final mins = (etaS! / 60).ceil();
    final wait = mins <= 1 ? 'about a minute' : 'about $mins minutes';
    return '$capabilityLabel loading — available in $wait';
  }
}

/// `routing`'s per-region breakdown (ARCH §8.3, D41; issue #154) — replaces
/// the pre-#154 single process-wide flag now that every trip bbox gets its
/// own graph. Keyed by the region id `RoutingClient.ensureRegion` returns.
class RoutingCapability {
  const RoutingCapability(this.regions);
  final Map<String, CapabilityStatus> regions;

  /// Null (not yet ensured) is deliberately distinct from "not ready" — a
  /// screen gating a control on this should show a wait/reason only once
  /// [RoutingClient.ensureRegion] has actually returned a key.
  CapabilityStatus? forRegion(String? key) => key == null ? null : regions[key];

  factory RoutingCapability.fromJson(Map<String, dynamic> json) => RoutingCapability({
        for (final entry in (json['regions'] as Map<String, dynamic>).entries)
          entry.key: CapabilityStatus.fromJson(entry.value as Map<String, dynamic>),
      });
}

/// Snapshot of `/health`'s `capabilities` object. `tiles` and `layers` are
/// ready as soon as the sidecar answers at all in this codebase (B1);
/// `routing` settles per region (issue #154) and `elevation` never settles
/// to ready in this codebase (gated on #148) but does settle to "stopped
/// trying" immediately — see `CapabilityStatus.failed`.
class Capabilities {
  const Capabilities({
    required this.tiles,
    required this.layers,
    required this.routing,
    required this.elevation,
  });

  final CapabilityStatus tiles;
  final CapabilityStatus layers;
  final RoutingCapability routing;
  final CapabilityStatus elevation;

  /// Elevation is the only capability here that ever *stays* unsettled
  /// (`routing` per-region view has nothing to poll once no more regions
  /// are being ensured) — kept for API continuity with call sites that used
  /// to gate a background poll on "has everything stopped changing".
  bool get settled => elevation.ready || elevation.failed;

  factory Capabilities.fromJson(Map<String, dynamic> json) => Capabilities(
        tiles: CapabilityStatus.fromJson(json['tiles'] as Map<String, dynamic>),
        layers: CapabilityStatus.fromJson(json['layers'] as Map<String, dynamic>),
        routing: RoutingCapability.fromJson(json['routing'] as Map<String, dynamic>),
        elevation: CapabilityStatus.fromJson(json['elevation'] as Map<String, dynamic>),
      );
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

  SidecarProcess? _process;
  int? _port;
  String? _confirmedVersion;
  SidecarStatus _status = const SidecarStatus(SidecarState.starting);
  bool _restarted = false;
  bool _stoppingDeliberately = false;
  Capabilities? _capabilities;
  Timer? _capabilityPollTimer;

  SidecarStatus get status => _status;
  int? get port => _port;
  String get baseUrl => 'http://127.0.0.1:${_port ?? 0}';

  /// The version the running sidecar reported at its last successful
  /// `--version` check (K10's About surface / M12's `/health` comparison).
  /// Null until a check has actually passed.
  String? get confirmedVersion => _confirmedVersion;

  /// Last-polled per-capability readiness (ARCH §8.3, PRD FR121). Null until
  /// the first successful `/health` response — which is also when [status]
  /// first reaches [SidecarState.ready], so a screen gated by `SidecarGate`
  /// can assume this is non-null. Kept live by a background poll (separate
  /// from the startup poll in [_pollUntilReady]) until [Capabilities.settled],
  /// so a screen like New Route can show routing/elevation loading in real
  /// time without the app being blocked on it (B1's whole point).
  Capabilities? get capabilities => _capabilities;

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

  /// A real app-support directory (issue #154) — per-region graph and tile
  /// caches (`regions/{key}/...`) live under here, built on demand from the
  /// Author's own trip bbox rather than the pre-#154 committed Boulder
  /// fixture. [cacheDirOverride] remains for tests that need a scratch
  /// directory instead of the OS's real app-support path.
  Future<Directory> _resolveCacheDir() async {
    final override = cacheDirOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/sidecar_cache');
    await dir.create(recursive: true);
    return dir;
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
    final cacheDir = await _resolveCacheDir();
    _set(SidecarState.starting, detail: 'launching sidecar');

    _process = await SidecarProcess.start(binPath, [
      '--port=$_port',
      '--host=127.0.0.1',
      '--mode=sidecar',
      '--cache-dir=${cacheDir.path}',
    ]);
    _process!.exitCode.then(_onExit);

    await _pollUntilReady();
  }

  /// Waits only for the sidecar process to come up and answer `/health` —
  /// not for full readiness. Tiles and layer/POI capabilities are ready the
  /// instant the process responds (ARCH B1/§8.3, PRD FR121), so that is what
  /// unblocks [SidecarGate] now; routing and elevation settle later and are
  /// tracked by [_watchCapabilities] without holding up the app.
  Future<void> _pollUntilReady() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      // Escalating honest wait message rather than a bare spinner (MVP §4).
      final waitDetail = attempt < 6
          ? 'starting up'
          : attempt < 15
              ? 'still starting — this can take a while on first launch'
              : 'taking longer than expected — still working, not stuck';
      _set(SidecarState.starting, detail: waitDetail);
      try {
        final resp = await http
            .get(Uri.parse('$baseUrl/health'))
            .timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body) as Map<String, dynamic>;
          final caps = Capabilities.fromJson(body['capabilities'] as Map<String, dynamic>);
          _capabilities = caps;
          if (caps.tiles.ready && caps.layers.ready) {
            _set(SidecarState.ready, detail: 'ready');
            _watchCapabilities();
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

  /// Keeps polling `/health` after the app has unblocked, purely to track
  /// per-region routing progress (ARCH §8.3, issue #154) — `SidecarGate` has
  /// already let the Author in by this point, so a poll failure here
  /// degrades a single screen's progress display, never the whole app.
  ///
  /// Runs for the session's lifetime rather than stopping once "settled":
  /// unlike the pre-#154 single-startup-sequence model, a trip's bbox is
  /// revisable throughout authoring (D41), so a new region can start
  /// building at any point, not only at startup. The cost of a 2s local
  /// loopback poll for the rest of the session is negligible.
  void _watchCapabilities() {
    _capabilityPollTimer?.cancel();
    _capabilityPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final resp = await http
            .get(Uri.parse('$baseUrl/health'))
            .timeout(const Duration(seconds: 2));
        if (resp.statusCode != 200) return;
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        _capabilities = Capabilities.fromJson(body['capabilities'] as Map<String, dynamic>);
        notifyListeners();
      } catch (_) {
        // Sidecar may have died mid-poll — `_onExit` handles that
        // transition; this loop just stops making noise until it's stopped.
      }
    });
  }

  void _onExit(int code) {
    _capabilityPollTimer?.cancel();
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

  /// Graceful stop, then a hard kill if the sidecar outlasts the grace
  /// period. The platform split lives in [SidecarProcess]: POSIX is
  /// `SIGTERM` → `SIGKILL`; Windows is `AttachConsole` + a muted default
  /// Ctrl handler + `CTRL_BREAK_EVENT`, since Windows cannot deliver
  /// `SIGTERM` and a GUI process has no console to signal through (ARCH
  /// §7.3; SPIKE-00 `WINDOWS.md` §3).
  Future<void> stop() async {
    _stoppingDeliberately = true;
    _capabilityPollTimer?.cancel();
    final proc = _process;
    if (proc == null) return;
    await proc.stop(grace: const Duration(seconds: 5));
    _set(SidecarState.stopped, detail: 'stopped');
  }
}

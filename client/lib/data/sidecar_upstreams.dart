import 'dart:io';

import 'package:flutter/foundation.dart';

/// Issue #434 — the upstream endpoints the client hands the sidecar it
/// spawns, so a stock desktop launch reaches the Plotlines mirror instead of
/// falling through to Overpass on every trip.
///
/// Phase 3 (epic #272) swapped the transport in the service: `ensure_graph`
/// and `OsmLayerProvider.fetch` build from a mirror-clipped `.osm.pbf`
/// whenever one is on disk, and `RegionState.build` fetches that clip on the
/// extent declaration — but only when the sidecar is started with
/// `--mirror-clip-url`. Until this class existed the spawn passed exactly
/// four flags (port, host, mode, cache dir), so `mirror_clip_url` was `None`
/// on every real install and the fallback was the only path ever taken.
///
/// **Where the values come from**, in precedence order:
///
///  1. A process environment variable at launch — the dev/QA override, so a
///     source run can be pointed at the LAN Pi (`PLOTLINES_MIRROR_URL=
///     http://tiles.plotlines.app`, with the DNS override from
///     `deploy/mirror/README.md` §6.5) or at nothing (`off`) without a
///     rebuild.
///  2. A `--dart-define` at build time — the release path. The client key
///     (#263) is **only** ever supplied this way or via the env var: it is
///     not a literal anywhere in the repo, and the shipped binary carries it
///     the same way any deploy secret reaches a built artifact, from the
///     builder's environment.
///  3. The built-in default: the Plotlines-operated mirror at
///     [defaultMirrorUrl], matching `tiles/mirror.py`'s `MIRROR_HOST`
///     posture (a test pins the two to each other). Only the mirror URL has
///     a default; the key, the state URL, and the elevation proxy have
///     none.
///
/// The literal `off` at any level disables that upstream outright — the
/// sidecar is then started without the flag, exactly as before #434, and
/// `/health` reports `capabilities.extract = {"configured": false}`.
///
/// This class is inert: resolving it and building the spawn args performs
/// no I/O. Nothing in the client ever contacts the mirror itself — the
/// sidecar does, once, when the Author declares an extent (D41/D57; #274's
/// first acceptance box). `sidecar_upstreams_test.dart` asserts both.
@immutable
class SidecarUpstreams {
  const SidecarUpstreams({
    this.mirrorUrl,
    this.mirrorClipClientKey,
    this.mirrorStateUrl,
    this.elevationUpstream,
  });

  /// No upstreams at all — the pre-#434 spawn, kept for tests and for a
  /// build explicitly cut off from the mirror.
  static const SidecarUpstreams none = SidecarUpstreams();

  /// The Plotlines-operated mirror. Its `/clip` endpoint is what the
  /// sidecar's `extract_fetch.ensure_extract` appends to this base URL;
  /// `MIRROR_STATE.json` sits beside it for the staleness monitor (#367).
  /// Pinned to `core/plotlines_core/tiles/mirror.py::MIRROR_HOST` by test.
  static const String defaultMirrorUrl = 'https://tiles.plotlines.app';

  /// Environment-variable / `--dart-define` names. One set of names for both
  /// channels so the README can document each once.
  static const String mirrorUrlVar = 'PLOTLINES_MIRROR_URL';
  static const String mirrorClipClientKeyVar = 'PLOTLINES_MIRROR_CLIP_CLIENT_KEY';
  static const String mirrorStateUrlVar = 'PLOTLINES_MIRROR_STATE_URL';
  static const String elevationUpstreamVar = 'PLOTLINES_ELEVATION_UPSTREAM';

  /// The literal that disables an upstream at any level.
  static const String off = 'off';

  // Build-time defines. `String.fromEnvironment` is only constant-foldable
  // as a `const` initialiser, which is why these are static consts rather
  // than read inside `resolve` — and why an absent define reads as the
  // empty string (unset) rather than the default, so the env var above it
  // can still win.
  static const String _defineMirrorUrl = String.fromEnvironment(mirrorUrlVar);
  static const String _defineMirrorClipClientKey =
      String.fromEnvironment(mirrorClipClientKeyVar);
  static const String _defineMirrorStateUrl = String.fromEnvironment(mirrorStateUrlVar);
  static const String _defineElevationUpstream =
      String.fromEnvironment(elevationUpstreamVar);

  /// Base URL of the mirror (no trailing `/clip`), or null for no mirror.
  final String? mirrorUrl;

  /// `X-Plotlines-Client-Key` for `/clip` (#263). Null sends no key, which
  /// only works against a mirror configured to leave `/clip` open.
  final String? mirrorClipClientKey;

  /// Where the sidecar reads `MIRROR_STATE.json` for `capabilities.mirror`.
  /// No default, deliberately: `/health` fetches this source on every poll
  /// — the client polls every 2 s — so a default here would be a request to
  /// the mirror before any extent is declared, and a 5 s fetch timeout
  /// against an unreachable mirror would blow the client's 2 s health
  /// timeout. Explicit dev/QA use only until #367 makes the read safe.
  final String? mirrorStateUrl;

  /// The Pi5 caching elevation proxy's `/dem` base URL (QA-only companion
  /// to #264, tracked apart from #148/FR87). No default.
  final String? elevationUpstream;

  /// Whether the sidecar will be told about a mirror at all.
  bool get mirrorConfigured => mirrorUrl != null;

  /// Resolves from [environment] (defaults to the real process environment)
  /// over the build-time defines over [defaultMirrorUrl]. Pure — no I/O.
  factory SidecarUpstreams.resolve({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    return SidecarUpstreams(
      mirrorUrl: _pick(env[mirrorUrlVar], _defineMirrorUrl, defaultMirrorUrl),
      mirrorClipClientKey:
          _pick(env[mirrorClipClientKeyVar], _defineMirrorClipClientKey, null),
      mirrorStateUrl: _pick(env[mirrorStateUrlVar], _defineMirrorStateUrl, null),
      elevationUpstream:
          _pick(env[elevationUpstreamVar], _defineElevationUpstream, null),
    );
  }

  /// First non-empty of env → define → default; the literal [off] at
  /// whichever level wins yields null. A trailing slash on a URL is dropped
  /// so `<url>/clip` composes cleanly either way.
  static String? _pick(String? fromEnv, String fromDefine, String? fallback) {
    for (final candidate in [fromEnv, fromDefine, fallback]) {
      final value = candidate?.trim();
      if (value == null || value.isEmpty) continue;
      if (value.toLowerCase() == off) return null;
      return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
    }
    return null;
  }

  /// The sidecar flags this configuration adds to the spawn (ARCH §7.3),
  /// after the four baseline flags. Empty for [none]. The key is only ever
  /// emitted alongside a mirror URL — a key with nowhere to send it is not
  /// an argument.
  List<String> toSidecarArgs() {
    final url = mirrorUrl;
    final key = mirrorClipClientKey;
    final state = mirrorStateUrl;
    final elevation = elevationUpstream;
    return [
      if (url != null) '--mirror-clip-url=$url',
      if (url != null && key != null) '--mirror-clip-client-key=$key',
      if (state != null) '--mirror-state-url=$state',
      if (elevation != null) '--elevation-upstream=$elevation',
    ];
  }

  /// A log-safe rendering: never includes the key, only whether one is set.
  @override
  String toString() => 'SidecarUpstreams('
      'mirrorUrl: $mirrorUrl, '
      'mirrorClipClientKey: ${mirrorClipClientKey == null ? 'unset' : 'set'}, '
      'mirrorStateUrl: $mirrorStateUrl, '
      'elevationUpstream: $elevationUpstream)';

  @override
  bool operator ==(Object other) =>
      other is SidecarUpstreams &&
      other.mirrorUrl == mirrorUrl &&
      other.mirrorClipClientKey == mirrorClipClientKey &&
      other.mirrorStateUrl == mirrorStateUrl &&
      other.elevationUpstream == elevationUpstream;

  @override
  int get hashCode =>
      Object.hash(mirrorUrl, mirrorClipClientKey, mirrorStateUrl, elevationUpstream);
}

/// The complete argv the client spawns the sidecar with (ARCH §7.3): the
/// four baseline flags every launch has carried since M12, then whatever
/// [upstreams] adds. A top-level pure function so "the spawn args carry
/// `--mirror-clip-url` when a mirror is configured, and not when it isn't"
/// is asserted on the exact list handed to `SidecarProcess.start`, without
/// spawning anything.
List<String> sidecarSpawnArgs({
  required int port,
  required String cacheDirPath,
  required SidecarUpstreams upstreams,
}) =>
    [
      '--port=$port',
      '--host=127.0.0.1',
      '--mode=sidecar',
      '--cache-dir=$cacheDirPath',
      ...upstreams.toSidecarArgs(),
    ];

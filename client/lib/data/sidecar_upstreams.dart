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
///     posture; and, once a mirror URL is configured at all, two paths
///     derived from it — the tiles upstream, which is the mirror root itself
///     (issue #519: the sidecar finds each tile's archive from the store's
///     record, so filled cells are read as they land) — and the state URL at `<mirrorUrl>/MIRROR_STATE.json` (issue #367 —
///     safe now that `_mirror_capability` caches the read rather than
///     fetching it on every 2s `/health` poll). Tests pin these to the core
///     side. The key and the elevation proxy have no default.
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
    this.tilesUpstream,
  });

  /// No upstreams at all — the pre-#434 spawn, kept for tests and for a
  /// build explicitly cut off from the mirror.
  static const SidecarUpstreams none = SidecarUpstreams();

  /// The Plotlines-operated mirror. Its `/clip` endpoint is what the
  /// sidecar's `extract_fetch.ensure_extract` appends to this base URL;
  /// `MIRROR_STATE.json` sits beside it for the staleness monitor (#367).
  /// Pinned to `core/plotlines_core/tiles/mirror.py::MIRROR_HOST` by test.
  static const String defaultMirrorUrl = 'https://tiles.plotlines.app';

  /// What a stock launch passes as `--tiles-upstream`: the mirror **root**
  /// (issue #519), not one archive. The sidecar reads the store's own record
  /// (`MIRROR_STATE.json`'s `areas`) to learn which archive covers a tile, so
  /// a cell the mirror fills (ARCH D67) is read without a new flag or a
  /// rebuild. Equal to `mirror.py::MIRROR_BASEMAP_ROOT_URL`, pinned by test.
  static const String defaultTilesUpstream = defaultMirrorUrl;

  /// Environment-variable / `--dart-define` names. One set of names for both
  /// channels so the README can document each once.
  static const String mirrorUrlVar = 'PLOTLINES_MIRROR_URL';
  static const String mirrorClipClientKeyVar = 'PLOTLINES_MIRROR_CLIP_CLIENT_KEY';
  static const String mirrorStateUrlVar = 'PLOTLINES_MIRROR_STATE_URL';
  static const String elevationUpstreamVar = 'PLOTLINES_ELEVATION_UPSTREAM';
  static const String tilesUpstreamVar = 'PLOTLINES_TILES_UPSTREAM';

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
  static const String _defineTilesUpstream = String.fromEnvironment(tilesUpstreamVar);

  /// Base URL of the mirror (no trailing `/clip`), or null for no mirror.
  final String? mirrorUrl;

  /// `X-Plotlines-Client-Key` for `/clip` (#263). Null sends no key, which
  /// only works against a mirror configured to leave `/clip` open.
  final String? mirrorClipClientKey;

  /// Where the sidecar reads `MIRROR_STATE.json` for `capabilities.mirror`.
  /// Defaults to `<mirrorUrl>/MIRROR_STATE.json` once a mirror URL is
  /// configured at all (issue #367) — a bare mirror-URL default was unsafe
  /// while `/health` re-fetched this source on every 2 s poll (a default
  /// would have been a request to the mirror on a fixed timer, before any
  /// extent is declared, and a stuck fetch would have blown the client's
  /// 2 s health timeout); `_mirror_capability` now caches the read for
  /// `_MIRROR_STATE_CACHE_TTL_S` and bounds the fetch on its own pool
  /// (`service/plotlines_service/app.py`), so this can default on like
  /// [mirrorUrl] and [tilesUpstream] do. Still overridable/disablable the
  /// same way as every other field here.
  final String? mirrorStateUrl;

  /// The Pi5 caching elevation proxy's `/dem` base URL (QA-only companion
  /// to #264, tracked apart from #148/FR87). No default.
  final String? elevationUpstream;

  /// The sidecar's `--tiles-upstream`: a PMTiles archive, or a store root
  /// the sidecar resolves archives under by area (issue #519). Defaults to
  /// the resolved [mirrorUrl] itself — the root — so a LAN or hosted mirror
  /// is read for tiles too, a cell the mirror fills (ARCH D67) shows up
  /// without a restart, and turning the mirror `off` turns this default off
  /// with it; the sidecar then serves only the shipped home region (FR96).
  /// `/health` reports the root's coverage per archive part, so the #318
  /// notice shows over the gaps between cells. Never combine this with
  /// `--allow-unmirrored-tiles` — [toSidecarArgs] never emits that flag, so a
  /// third-party host here is refused by the sidecar (`HotlinkRefused`,
  /// FR92/FR95), not allowed through.
  final String? tilesUpstream;

  /// Whether the sidecar will be told about a mirror at all.
  bool get mirrorConfigured => mirrorUrl != null;

  /// Resolves from [environment] (defaults to the real process environment)
  /// over the build-time defines over [defaultMirrorUrl]. Pure — no I/O.
  factory SidecarUpstreams.resolve({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final mirrorUrl = _pick(env[mirrorUrlVar], _defineMirrorUrl, defaultMirrorUrl);
    return SidecarUpstreams(
      mirrorUrl: mirrorUrl,
      mirrorClipClientKey:
          _pick(env[mirrorClipClientKeyVar], _defineMirrorClipClientKey, null),
      // Issue #367 — derived from the resolved mirror URL, not a literal
      // default of its own, so `off`/an env override on `mirrorUrl` alone
      // (no explicit `mirrorStateUrl`) still turns this off too rather than
      // leaving it pointed at a mirror the sidecar was told to ignore.
      mirrorStateUrl: _pick(env[mirrorStateUrlVar], _defineMirrorStateUrl,
          mirrorUrl == null ? null : '$mirrorUrl/MIRROR_STATE.json'),
      elevationUpstream:
          _pick(env[elevationUpstreamVar], _defineElevationUpstream, null),
      // Issue #539/#519 — the resolved mirror URL itself (the store root),
      // like the state URL above, so a configured mirror is read for tiles
      // and `off` turns both off. An explicit env/define value still wins.
      tilesUpstream: _pick(env[tilesUpstreamVar], _defineTilesUpstream, mirrorUrl),
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
  /// after the four baseline flags. Empty for [none]. The client key is never
  /// one of them — see [toSidecarEnvironment].
  List<String> toSidecarArgs() {
    final url = mirrorUrl;
    final state = mirrorStateUrl;
    final elevation = elevationUpstream;
    final tiles = tilesUpstream;
    return [
      if (url != null) '--mirror-clip-url=$url',
      if (state != null) '--mirror-state-url=$state',
      if (elevation != null) '--elevation-upstream=$elevation',
      if (tiles != null) '--tiles-upstream=$tiles',
    ];
  }

  /// The variables this configuration adds to the sidecar's environment. The
  /// client key travels here rather than as `--mirror-clip-client-key`: argv
  /// is readable by any local user (`ps`, `/proc/<pid>/cmdline`), the
  /// environment is not. The sidecar reads the same variable name. The key is
  /// only ever set alongside a mirror URL — a key with nowhere to send it is
  /// not passed on.
  Map<String, String> toSidecarEnvironment() {
    final key = mirrorClipClientKey;
    return {
      if (mirrorUrl != null && key != null) mirrorClipClientKeyVar: key,
    };
  }

  /// A log-safe rendering: never includes the key, only whether one is set.
  @override
  String toString() => 'SidecarUpstreams('
      'mirrorUrl: $mirrorUrl, '
      'mirrorClipClientKey: ${mirrorClipClientKey == null ? 'unset' : 'set'}, '
      'mirrorStateUrl: $mirrorStateUrl, '
      'elevationUpstream: $elevationUpstream, '
      'tilesUpstream: $tilesUpstream)';

  @override
  bool operator ==(Object other) =>
      other is SidecarUpstreams &&
      other.mirrorUrl == mirrorUrl &&
      other.mirrorClipClientKey == mirrorClipClientKey &&
      other.mirrorStateUrl == mirrorStateUrl &&
      other.elevationUpstream == elevationUpstream &&
      other.tilesUpstream == tilesUpstream;

  @override
  int get hashCode => Object.hash(
      mirrorUrl, mirrorClipClientKey, mirrorStateUrl, elevationUpstream, tilesUpstream);
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

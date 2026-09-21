// Issue #434 — a stock desktop launch must start the sidecar with
// `--mirror-clip-url` (and the #263 client key) when a mirror is configured,
// and without either when it isn't, so Phase 3's transport swap (#272) is
// reachable from the app rather than only from a hand-launched sidecar.
//
// Everything here runs without a binary: the spawn argv is a pure function
// (`sidecarSpawnArgs`) of the port, the cache dir, and `SidecarUpstreams`,
// and `SidecarManager.spawnArgsFor` is the exact list `start()` hands to
// `SidecarProcess.start`. The one piece that touches the network is the
// "no request before an extent is declared" check, and it does so only to
// prove a negative — a loopback stand-in for the mirror records zero hits.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/data/sidecar_upstreams.dart';

/// `core/plotlines_core/tiles/mirror.py`'s `MIRROR_HOST` literal, read off
/// the source so the two sides are pinned to each other rather than to a
/// value someone remembered. `flutter test` runs with `client/` as cwd.
String pythonMirrorHost() {
  final file = File('${Directory.current.parent.path}/core/plotlines_core/tiles/mirror.py');
  final match = RegExp(r'^MIRROR_HOST\s*=\s*"([^"]+)"', multiLine: true)
      .firstMatch(file.readAsStringSync());
  if (match == null) throw StateError('MIRROR_HOST not found in ${file.path}');
  return match.group(1)!;
}

void main() {
  const baseline = ['--port=51234', '--host=127.0.0.1', '--mode=sidecar', '--cache-dir=/tmp/c'];

  group('SidecarUpstreams.resolve — where the values come from', () {
    test('a stock launch defaults to the Plotlines-operated mirror and its primary region', () {
      final u = SidecarUpstreams.resolve(environment: const {});
      expect(u.mirrorUrl, SidecarUpstreams.defaultMirrorUrl);
      expect(u.mirrorConfigured, isTrue);
      expect(u.mirrorClipClientKey, isNull,
          reason: 'the key has no built-in default — it is never a literal in the repo');
      expect(u.mirrorStateUrl, isNull,
          reason: '/health fetches this on every 2 s poll; a default would be a '
              'request before any extent is declared (#367 owns making that safe)');
      expect(u.elevationUpstream, isNull, reason: 'QA-only proxy, no default (#148/FR87)');
      expect(u.tilesUpstream, SidecarUpstreams.defaultTilesUpstream,
          reason: 'issue #457: the mirror\'s primary covered region is now the '
              'built-in default, same as the mirror URL itself');
    });

    test("the default mirror host matches tiles/mirror.py's MIRROR_HOST", () {
      expect(Uri.parse(SidecarUpstreams.defaultMirrorUrl).host, pythonMirrorHost());
      expect(Uri.parse(SidecarUpstreams.defaultMirrorUrl).scheme, 'https');
    });

    test("the default tiles upstream matches tiles/mirror.py's MIRROR_WNC_CORRIDOR_URL", () {
      // `MIRROR_WNC_CORRIDOR_URL` is built from three constants at import
      // time on the Python side — reconstructed here from the same two
      // source literals (PROTOMAPS_BASEMAP_BUILD, MIRROR_HOST) plus the
      // stable "-wnc/corridor.pmtiles" suffix `WNC_CORRIDOR_BUILD_ID` and
      // the pmtiles filename both hard-code, rather than parsing Python
      // f-string concatenation out of the source text.
      final file = File(
          '${Directory.current.parent.path}/core/plotlines_core/tiles/mirror.py');
      final source = file.readAsStringSync();
      final host = RegExp(r'^MIRROR_HOST\s*=\s*"([^"]+)"', multiLine: true)
          .firstMatch(source)!.group(1)!;
      final protomapsBuild = RegExp(r'^PROTOMAPS_BASEMAP_BUILD\s*=\s*"([^"]+)"', multiLine: true)
          .firstMatch(source)!.group(1)!;
      expect(source, contains('WNC_CORRIDOR_BUILD_ID = f"{PROTOMAPS_BASEMAP_BUILD}-wnc"'));
      expect(SidecarUpstreams.defaultTilesUpstream,
          'https://$host/basemap/protomaps/$protomapsBuild-wnc/corridor.pmtiles');
    });

    test('an environment variable overrides the default mirror URL', () {
      final u = SidecarUpstreams.resolve(environment: const {
        SidecarUpstreams.mirrorUrlVar: 'http://tiles.plotlines.app',
      });
      expect(u.mirrorUrl, 'http://tiles.plotlines.app');
    });

    test('a trailing slash is dropped so <url>/clip composes cleanly', () {
      final u = SidecarUpstreams.resolve(environment: const {
        SidecarUpstreams.mirrorUrlVar: 'http://127.0.0.1:8095/',
      });
      expect(u.mirrorUrl, 'http://127.0.0.1:8095');
    });

    test('the literal "off" disables the mirror outright', () {
      for (final spelling in const ['off', 'OFF', ' Off ']) {
        final u = SidecarUpstreams.resolve(environment: {SidecarUpstreams.mirrorUrlVar: spelling});
        expect(u.mirrorUrl, isNull, reason: spelling);
        expect(u.mirrorConfigured, isFalse, reason: spelling);
      }
    });

    test('an empty environment value reads as unset, not as a URL', () {
      final u = SidecarUpstreams.resolve(environment: const {
        SidecarUpstreams.mirrorUrlVar: '',
        SidecarUpstreams.mirrorClipClientKeyVar: '   ',
      });
      expect(u.mirrorUrl, SidecarUpstreams.defaultMirrorUrl);
      expect(u.mirrorClipClientKey, isNull);
    });

    test('the key, state URL, elevation proxy, and tiles upstream come from the environment', () {
      final u = SidecarUpstreams.resolve(environment: const {
        SidecarUpstreams.mirrorClipClientKeyVar: 'k-test',
        SidecarUpstreams.mirrorStateUrlVar: 'https://tiles.plotlines.app/MIRROR_STATE.json',
        SidecarUpstreams.elevationUpstreamVar: 'http://argon-robot:8096/dem',
        SidecarUpstreams.tilesUpstreamVar:
            'http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles',
      });
      expect(u.mirrorClipClientKey, 'k-test');
      expect(u.mirrorStateUrl, 'https://tiles.plotlines.app/MIRROR_STATE.json');
      expect(u.elevationUpstream, 'http://argon-robot:8096/dem');
      expect(u.tilesUpstream,
          'http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles');
    });

    test('the literal "off" disables the tiles upstream outright', () {
      final u = SidecarUpstreams.resolve(environment: const {
        SidecarUpstreams.tilesUpstreamVar: 'off',
      });
      expect(u.tilesUpstream, isNull);
    });

    test('resolving is pure — the same input gives an equal value', () {
      const env = {SidecarUpstreams.mirrorUrlVar: 'http://x', SidecarUpstreams.mirrorClipClientKeyVar: 'k'};
      expect(SidecarUpstreams.resolve(environment: env), SidecarUpstreams.resolve(environment: env));
      expect(SidecarUpstreams.resolve(environment: env).hashCode,
          SidecarUpstreams.resolve(environment: env).hashCode);
    });
  });

  group('the client key is never committed in cleartext (#263, #434 AC)', () {
    test('the build-time define for the key carries no default value', () {
      // The key reaches a build only via `--dart-define` or the process
      // environment. A `defaultValue:` on that define would be exactly the
      // string literal in a public repo the acceptance criterion forbids.
      final source = File('${Directory.current.path}/lib/data/sidecar_upstreams.dart')
          .readAsStringSync();
      final keyDefine = RegExp(
              r"String\.fromEnvironment\(\s*mirrorClipClientKeyVar\s*(,[^)]*)?\)")
          .firstMatch(source);
      expect(keyDefine, isNotNull, reason: 'the key define must exist');
      expect(keyDefine!.group(1), isNull,
          reason: 'the key define must not carry a defaultValue');
    });

    test('toString never renders the key', () {
      final u = SidecarUpstreams.resolve(environment: const {
        SidecarUpstreams.mirrorClipClientKeyVar: 'secret-k',
      });
      expect(u.toString(), isNot(contains('secret-k')));
      expect(u.toString(), contains('mirrorClipClientKey: set'));
      expect(SidecarUpstreams.none.toString(), contains('mirrorClipClientKey: unset'));
    });
  });

  group('toSidecarArgs / sidecarSpawnArgs — what the sidecar is started with', () {
    test('a configured mirror adds --mirror-clip-url and the key', () {
      const u = SidecarUpstreams(
          mirrorUrl: 'https://tiles.plotlines.app', mirrorClipClientKey: 'k');
      expect(u.toSidecarArgs(), [
        '--mirror-clip-url=https://tiles.plotlines.app',
        '--mirror-clip-client-key=k',
      ]);
    });

    test('no mirror configured adds nothing — the pre-#434 spawn exactly', () {
      expect(SidecarUpstreams.none.toSidecarArgs(), isEmpty);
      expect(
        sidecarSpawnArgs(port: 51234, cacheDirPath: '/tmp/c', upstreams: SidecarUpstreams.none),
        baseline,
      );
    });

    test('a key with no mirror URL is not an argument', () {
      const u = SidecarUpstreams(mirrorClipClientKey: 'k');
      expect(u.toSidecarArgs(), isEmpty);
    });

    test('a mirror without a key sends the URL alone (open /clip, local/dev)', () {
      const u = SidecarUpstreams(mirrorUrl: 'http://127.0.0.1:8095');
      expect(u.toSidecarArgs(), ['--mirror-clip-url=http://127.0.0.1:8095']);
    });

    test('--mirror-state-url and --elevation-upstream thread through only when set', () {
      const u = SidecarUpstreams(
        mirrorUrl: 'https://tiles.plotlines.app',
        mirrorStateUrl: 'https://tiles.plotlines.app/MIRROR_STATE.json',
        elevationUpstream: 'http://argon-robot:8096/dem',
      );
      expect(u.toSidecarArgs(), [
        '--mirror-clip-url=https://tiles.plotlines.app',
        '--mirror-state-url=https://tiles.plotlines.app/MIRROR_STATE.json',
        '--elevation-upstream=http://argon-robot:8096/dem',
      ]);
    });

    test('a configured tiles upstream adds --tiles-upstream (issue #453)', () {
      const u = SidecarUpstreams(
        tilesUpstream: 'http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles',
      );
      expect(u.toSidecarArgs(), [
        '--tiles-upstream=http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles',
      ]);
    });

    test('no tiles upstream configured adds nothing', () {
      expect(SidecarUpstreams.none.toSidecarArgs(), isNot(contains(startsWith('--tiles-upstream'))));
      const u = SidecarUpstreams(mirrorUrl: 'https://tiles.plotlines.app');
      expect(u.toSidecarArgs().where((a) => a.startsWith('--tiles-upstream')), isEmpty);
    });

    test('the client never emits --allow-unmirrored-tiles, whatever the tiles upstream', () {
      const u = SidecarUpstreams(tilesUpstream: 'http://evil.example.com/tiles.pmtiles');
      expect(u.toSidecarArgs(), isNot(contains('--allow-unmirrored-tiles')));
      expect(u.toSidecarArgs().any((a) => a.contains('allow-unmirrored')), isFalse,
          reason: 'a third-party host is refused by the sidecar (HotlinkRefused, '
              'FR92/FR95), never allowed through from the client');
    });

    test('the four baseline flags keep their order and come first', () {
      final args = sidecarSpawnArgs(
        port: 51234,
        cacheDirPath: '/tmp/c',
        upstreams: const SidecarUpstreams(mirrorUrl: 'https://tiles.plotlines.app'),
      );
      expect(args.sublist(0, 4), baseline);
      expect(args.last, '--mirror-clip-url=https://tiles.plotlines.app');
    });

    test('a stock launch (nothing in the environment) carries the mirror flag', () {
      final args = sidecarSpawnArgs(
        port: 51234,
        cacheDirPath: '/tmp/c',
        upstreams: SidecarUpstreams.resolve(environment: const {}),
      );
      expect(args, contains('--mirror-clip-url=${SidecarUpstreams.defaultMirrorUrl}'));
      expect(args.where((a) => a.startsWith('--mirror-clip-client-key=')), isEmpty,
          reason: 'no key without a define or env var — the mirror decides '
              'whether an unkeyed /clip is accepted (#263)');
      expect(args, contains('--tiles-upstream=${SidecarUpstreams.defaultTilesUpstream}'),
          reason: 'issue #457: a stock launch now points at the mirror\'s primary '
              'covered region by default');
    });
  });

  group('SidecarManager.spawnArgsFor — the list start() hands to SidecarProcess', () {
    test('an injected SidecarUpstreams is what gets spawned', () {
      final manager = SidecarManager(
        upstreams: const SidecarUpstreams(
            mirrorUrl: 'http://127.0.0.1:8095', mirrorClipClientKey: 'k'),
      );
      expect(manager.spawnArgsFor(port: 51234, cacheDir: Directory('/tmp/c')), [
        ...baseline,
        '--mirror-clip-url=http://127.0.0.1:8095',
        '--mirror-clip-client-key=k',
      ]);
    });

    test('an injected tiles upstream reaches the spawn (issue #453)', () {
      final manager = SidecarManager(
        upstreams: const SidecarUpstreams(
            tilesUpstream:
                'http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles'),
      );
      expect(manager.spawnArgsFor(port: 51234, cacheDir: Directory('/tmp/c')), [
        ...baseline,
        '--tiles-upstream=http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles',
      ]);
    });

    test('SidecarUpstreams.none spawns exactly the pre-#434 four flags', () {
      final manager = SidecarManager(upstreams: SidecarUpstreams.none);
      expect(manager.spawnArgsFor(port: 51234, cacheDir: Directory('/tmp/c')), baseline);
    });

    test('with nothing injected, the manager resolves from the environment once', () {
      final manager = SidecarManager();
      expect(identical(manager.upstreams, manager.upstreams), isTrue,
          reason: 'a restart-once relaunch must spawn with the same flags');
      expect(manager.upstreams.mirrorConfigured, isTrue,
          reason: 'this test process sets no PLOTLINES_MIRROR_URL, so the default applies');
    });
  });

  group('no request to the mirror before an extent is declared (D41/D57)', () {
    test('configuring, resolving, and building spawn args never contacts the mirror', () async {
      // A loopback stand-in for the mirror that counts every request it
      // sees. The client side of #434 (and #453's tiles upstream) is inert
      // by construction — the URL is an argv string until the sidecar, on
      // an extent declaration, asks /clip or extracts tiles for that bbox
      // (#274 asserts the service half: polling /health alone makes no
      // request).
      var hits = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        hits++;
        req.response
          ..statusCode = 200
          ..close();
      });
      final mirror = 'http://127.0.0.1:${server.port}';

      final upstreams = SidecarUpstreams.resolve(environment: {
        SidecarUpstreams.mirrorUrlVar: mirror,
        SidecarUpstreams.mirrorClipClientKeyVar: 'k',
        SidecarUpstreams.mirrorStateUrlVar: '$mirror/MIRROR_STATE.json',
        SidecarUpstreams.tilesUpstreamVar: '$mirror/basemap/protomaps/20250101-wnc/corridor.pmtiles',
      });
      final manager = SidecarManager(upstreams: upstreams);
      final args = manager.spawnArgsFor(port: 51234, cacheDir: Directory('/tmp/c'));
      expect(args, contains('--mirror-clip-url=$mirror'));
      expect(args, contains('--tiles-upstream=$mirror/basemap/protomaps/20250101-wnc/corridor.pmtiles'));

      // Give any stray request every chance to land before asserting.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hits, 0);
    });
  });
}

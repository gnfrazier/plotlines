// Issue #184 — `MapTileAssets.theme` must keep the four basemap-style
// failure modes distinct (a typed `BasemapThemeResult`, not a bare
// `null`), log each once, report the paths it tried, and not pin a
// transient failure in the cache. `loadBasemapTheme` is the pure core
// exercised directly here with injected `exists`/`read` seams.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';

void main() {
  test('no file at any candidate path → styleNotFound, every path reported', () async {
    final paths = ['/no/such/a.json', '/no/such/b.json', '/no/such/c.json'];
    final result = await loadBasemapTheme(paths, exists: (_) => false);

    expect(result.ok, isFalse);
    expect(result.theme, isNull);
    expect(result.error, BasemapThemeError.styleNotFound);
    expect(result.cause, isNull);
    expect(result.pathsSearched, paths);
  });

  test('file present but unreadable → styleUnreadable, carries the cause', () async {
    final result = await loadBasemapTheme(
      ['/present/style.json'],
      exists: (_) => true,
      read: (_) async => throw const FileSystemException('permission denied'),
    );

    expect(result.error, BasemapThemeError.styleUnreadable);
    expect(result.cause, isA<FileSystemException>());
    expect(result.pathsSearched, ['/present/style.json']);
  });

  test('file present but not valid JSON → styleMalformed', () async {
    final result = await loadBasemapTheme(
      ['/present/style.json'],
      exists: (_) => true,
      read: (_) async => 'this is not json {{{',
    );

    expect(result.error, BasemapThemeError.styleMalformed);
    expect(result.cause, isNotNull);
    expect(result.pathsSearched, ['/present/style.json']);
  });

  test('valid JSON that is not a style object → styleMalformed', () async {
    // A JSON array decodes fine but is not a `Map<String, dynamic>`.
    final result = await loadBasemapTheme(
      ['/present/style.json'],
      exists: (_) => true,
      read: (_) async => '[1, 2, 3]',
    );

    expect(result.error, BasemapThemeError.styleMalformed);
  });

  test('well-formed JSON object that ThemeReader rejects → themeRejected', () async {
    // No `layers` key — `ThemeReader.read` throws casting `null` to List.
    final result = await loadBasemapTheme(
      ['/present/style.json'],
      exists: (_) => true,
      read: (_) async => '{"version": 8, "name": "broken"}',
    );

    expect(result.error, BasemapThemeError.themeRejected);
    expect(result.cause, isNotNull);
    expect(result.pathsSearched, ['/present/style.json']);
  });

  test('the first existing candidate is the one opened', () async {
    final opened = <String>[];
    final result = await loadBasemapTheme(
      ['/a.json', '/b.json', '/c.json'],
      exists: (p) => p == '/b.json',
      read: (p) async {
        opened.add(p);
        return '{"version": 8, "layers": []}';
      },
    );

    expect(result.ok, isTrue);
    expect(opened, ['/b.json']);
  });

  test('every failure mode is logged exactly once', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);

    await loadBasemapTheme(['/x.json'], exists: (_) => false);
    await loadBasemapTheme(['/x.json'],
        exists: (_) => true, read: (_) async => throw const FileSystemException('io'));
    await loadBasemapTheme(['/x.json'], exists: (_) => true, read: (_) async => 'nope');
    await loadBasemapTheme(['/x.json'],
        exists: (_) => true, read: (_) async => '{"version": 8}');

    expect(lines, hasLength(4));
    expect(lines.every((l) => l.startsWith('basemap:')), isTrue);
    // The not-found log includes the searched path list.
    expect(lines.first, contains('/x.json'));
  });

  group('candidateStylePaths', () {
    test('includes the bundled path and the CWD-relative asset paths', () {
      final paths = MapTileAssets.candidateStylePaths('light');

      expect(paths.first, contains('data/flutter_assets/assets/map_style/style_light.json'));
      expect(paths.any((p) => p.endsWith('/client/assets/map_style/style_light.json')), isTrue);
      expect(paths.any((p) => p.endsWith('/assets/map_style/style_light.json')), isTrue);
      expect(paths.length, greaterThan(3));
    });
  });

  group('MapTileAssets.theme caching', () {
    test('a successful load is cached — same future on repeat calls', () async {
      // The committed style ships at `client/assets/map_style/` and the
      // test CWD is `client/`, so this resolves for real.
      final first = MapTileAssets.theme('light');
      final second = MapTileAssets.theme('light');
      expect(identical(first, second), isTrue);

      final result = await first;
      expect(result.ok, isTrue, reason: 'committed style_light.json should parse');
    });

    test('a failed load is evicted so a later call retries', () async {
      final failing = MapTileAssets.theme('does-not-exist-anywhere');
      final result = await failing;
      expect(result.error, BasemapThemeError.styleNotFound);
      await Future<void>.delayed(Duration.zero); // let the eviction .then() run

      // Once settled, the failure is gone from the cache: the next call
      // starts a fresh future rather than handing back the failed one.
      final retry = MapTileAssets.theme('does-not-exist-anywhere');
      expect(identical(failing, retry), isFalse);
      await retry;
    });
  });
}

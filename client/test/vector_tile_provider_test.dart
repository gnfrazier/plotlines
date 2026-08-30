// Regression coverage for the basemap gap this test exists because of:
// SPIKE-14 already extracted real tiles and vendored the `pmtiles` CLI, and
// issue #154 moved tile serving off local disk and onto the sidecar
// (`GET /tiles/{z}/{x}/{y}`, FR92) — `SidecarVectorTileProvider` is the
// client-side half of that. These tests run a small local `HttpServer`
// standing in for the sidecar rather than spawning the real process; the
// style-JSON parse tests below are unaffected by that move and still read
// the real committed asset.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart'
    show ProviderException, Retryable, TileIdentity;
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'package:plotlines_client/presentation/map/vector_tile_provider.dart';

/// A minimal HTTP server standing in for the sidecar's `/tiles/{z}/{x}/{y}`
/// (issue #154) — serves [tileBytes] gzip-encoded with the same
/// `Content-Encoding: gzip` header `service/plotlines_service/app.py`'s real
/// endpoint sends, for exactly one z/x/y and 404s everything else.
class _FakeTileServer {
  _FakeTileServer(this.tileBytes);
  final List<int> tileBytes;
  final int z = 10, x = 277, y = 403;
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final parts = request.uri.pathSegments;
      if (parts.length == 4 &&
          parts[0] == 'tiles' &&
          parts[1] == '$z' &&
          parts[2] == '$x' &&
          parts[3] == '$y') {
        request.response.headers.set('Content-Encoding', 'gzip');
        request.response.headers.contentType =
            ContentType('application', 'vnd.mapbox-vector-tile');
        request.response.add(gzip.encode(tileBytes));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late List<int> realTileBytes;
  late List<int> emptyTileBytes;

  setUpAll(() async {
    realTileBytes =
        await File('${Directory.current.path}/test/fixtures/buncombe_z10_277_403.mvt').readAsBytes();
    // A structurally valid MVT that decodes cleanly to layers with zero
    // features — the "background-only render" shape from issue #155.
    emptyTileBytes =
        await File('${Directory.current.path}/test/fixtures/empty_tile.mvt').readAsBytes();
  });

  test('provide() fetches and gzip-decodes a real tile from the sidecar', () async {
    final server = _FakeTileServer(realTileBytes);
    await server.start();
    try {
      final provider = SidecarVectorTileProvider(server.baseUrl);
      final bytes = await provider.provide(TileIdentity(10, 277, 403));
      expect(bytes, realTileBytes);
      final tile = VectorTileReader().read(bytes);
      expect(tile.layers, isNotEmpty);
    } finally {
      await server.stop();
    }
  });

  test('provide() throws a non-retryable ProviderException on 404', () async {
    final server = _FakeTileServer(realTileBytes);
    await server.start();
    try {
      final provider = SidecarVectorTileProvider(server.baseUrl);
      await expectLater(
        provider.provide(TileIdentity(3, 1, 1)),
        throwsA(isA<ProviderException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.retryable, 'retryable', Retryable.none)),
      );
    } finally {
      await server.stop();
    }
  });

  test('provide() refuses a zero-feature tile as retryable so no blank render is cached', () async {
    // Issue #155: `VectorTileLayer` raster mode renders a featureless tile
    // to a background-only PNG and freezes it on disk for 30 days. The
    // provider rejects it before the renderer ever sees it — retryable, so
    // the tile is re-fetched on the next visit rather than poisoned.
    final tile = VectorTileReader().read(Uint8List.fromList(emptyTileBytes));
    expect(tile.layers.every((l) => l.features.isEmpty), isTrue,
        reason: 'fixture must actually be feature-free for this test to mean anything');

    final server = _FakeTileServer(emptyTileBytes);
    await server.start();
    try {
      final provider = SidecarVectorTileProvider(server.baseUrl);
      await expectLater(
        provider.provide(TileIdentity(10, 277, 403)),
        throwsA(isA<ProviderException>().having((e) => e.retryable, 'retryable', Retryable.retry)),
      );
    } finally {
      await server.stop();
    }
  });

  test('a later visit renders features once data is available for a poisoned address', () async {
    // The poisoning shape end to end: the address first serves a blank
    // (nothing is cached because `provide()` threw), then serves real data —
    // the next load must return features, not a frozen blank.
    final address = TileIdentity(10, 277, 403);

    final blankServer = _FakeTileServer(emptyTileBytes);
    await blankServer.start();
    try {
      final provider = SidecarVectorTileProvider(blankServer.baseUrl);
      await expectLater(provider.provide(address), throwsA(isA<ProviderException>()));
    } finally {
      await blankServer.stop();
    }

    final dataServer = _FakeTileServer(realTileBytes);
    await dataServer.start();
    try {
      final provider = SidecarVectorTileProvider(dataServer.baseUrl);
      final bytes = await provider.provide(address);
      final tile = VectorTileReader().read(bytes);
      expect(tile.layers.any((l) => l.features.isNotEmpty), isTrue);
    } finally {
      await dataServer.stop();
    }
  });

  test('provide() treats an empty response body as a retryable gap', () async {
    final server = _FakeTileServer(const []);
    await server.start();
    try {
      final provider = SidecarVectorTileProvider(server.baseUrl);
      await expectLater(
        provider.provide(TileIdentity(10, 277, 403)),
        throwsA(isA<ProviderException>().having((e) => e.retryable, 'retryable', Retryable.retry)),
      );
    } finally {
      await server.stop();
    }
  });

  test('provide() throws a retryable ProviderException when the sidecar is unreachable', () async {
    // No server started at this port — an honest "sidecar unreachable"
    // rather than a silent hang or a substituted tile.
    final provider = SidecarVectorTileProvider('http://127.0.0.1:1');
    await expectLater(
      provider.provide(TileIdentity(10, 277, 403)),
      throwsA(isA<ProviderException>().having((e) => e.retryable, 'retryable', Retryable.retry)),
    );
  });

  group('basemap raster cache folder (issue #155)', () {
    test('leaf folder is keyed by the archive id and sanitised', () {
      expect(basemapCacheLeaf('abc123def456'), 'abc123def456');
      expect(basemapCacheLeaf('a/b c:d'), 'a-b-c-d');
    });

    test('a missing archive id collapses to one un-versioned bucket', () {
      expect(basemapCacheLeaf(null), 'unversioned');
      expect(basemapCacheLeaf(''), 'unversioned');
    });

    test('sweeping drops every sibling render folder except the one in use', () {
      final root = Directory.systemTemp.createTempSync('basemap_cache_test');
      try {
        final stale1 = Directory('${root.path}/old-archive-1')..createSync();
        final stale2 = Directory('${root.path}/old-archive-2')..createSync();
        File('${stale1.path}/default-9-138-201.png').writeAsBytesSync([0]);
        final keep = Directory('${root.path}/current-archive')..createSync();

        sweepStaleArchiveFolders(root, keep: keep);

        expect(keep.existsSync(), isTrue);
        expect(stale1.existsSync(), isFalse);
        expect(stale2.existsSync(), isFalse);
      } finally {
        root.deleteSync(recursive: true);
      }
    });
  });

  test('both style themes parse into a renderable Theme', () async {
    for (final name in ['light', 'dark']) {
      final path = '${Directory.current.path}/assets/map_style/style_$name.json';
      final json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final theme = ThemeReader().read(json);
      expect(theme.layers, isNotEmpty, reason: '$name theme should have layer rules');
    }
  });

  // Regression coverage for ARCH D24: the committed style JSON was, for one
  // session, a raw copy of the mirrored Protomaps theme rather than the
  // output of `packaging/build_basemap_theme.py` — parses fine (the prior
  // test above), but every symbol layer's `text-field` used an expression
  // form (`case`/`coalesce`/`is-supported-script`) the renderer doesn't
  // evaluate, so `ThemeReader` logs a warning per layer and draws no text —
  // labels silently missing despite every other test passing. This asserts
  // the actual signal: zero "unsupported expression" warnings during parse.
  test('style themes have no unsupported label expressions (ARCH D24)', () async {
    for (final name in ['light', 'dark']) {
      final path = '${Directory.current.path}/assets/map_style/style_$name.json';
      final json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final logger = _CollectingLogger();
      final theme = ThemeReader(logger: logger).read(json);
      final symbolLayers = theme.layers.where((l) => l.type == ThemeLayerType.symbol);
      expect(symbolLayers, isNotEmpty, reason: '$name theme should have label layers');
      expect(
        logger.warnings.where((w) => w.contains('Unsupported expression')),
        isEmpty,
        reason: '$name theme has an unevaluatable text-field or filter expression: '
            '${logger.warnings}',
      );
    }
  });
}

class _CollectingLogger implements Logger {
  final warnings = <String>[];
  @override
  void log(MessageFunction message) {}
  @override
  void warn(MessageFunction message) => warnings.add(message());
}

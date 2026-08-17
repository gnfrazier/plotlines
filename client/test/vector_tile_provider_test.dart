// Regression coverage for the basemap gap this test exists because of:
// SPIKE-14 already extracted real tiles and vendored the `pmtiles` CLI
// (spikes/SPIKE-14/tiles/boulder.pmtiles, spikes/SPIKE-14/tools/pmtiles),
// but nothing read them until this file's subject was written. This test
// only proves the plumbing (tile bytes parse, style JSON parses) — the
// actual rendering is `vector_map_tiles`/`vector_tile_renderer`'s concern,
// already proven by SPIKE-14's own benchmark screenshots.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' show TileIdentity;
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'package:plotlines_client/presentation/map/vector_tile_provider.dart';

void main() {
  test('resolveTilesRoot finds the exploded Boulder tile tree', () {
    final root = resolveTilesRoot();
    expect(root, isNotNull, reason: 'client/assets/tiles should exist and be found from cwd');
    expect(File('${root!.path}/9/106/193.mvt').existsSync(), isTrue);
  });

  test('a real extracted tile parses as valid MVT', () async {
    final root = resolveTilesRoot()!;
    final provider = DirectoryVectorTileProvider(root);
    final bytes = await provider.provide(TileIdentity(9, 106, 193));
    final tile = VectorTileReader().read(bytes);
    expect(tile.layers, isNotEmpty);
    expect(provider.reads, 1);
    expect(provider.misses, 0);
  });

  test('both style themes parse into a renderable Theme', () async {
    for (final name in ['light', 'dark']) {
      final path = '${Directory.current.path}/assets/map_style/style_$name.json';
      final json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final theme = ThemeReader().read(json);
      expect(theme.layers, isNotEmpty, reason: '$name theme should have layer rules');
    }
  });
}

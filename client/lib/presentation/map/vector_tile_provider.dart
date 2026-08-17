// Real basemap tiles (ARCH D22/D23/D24, SPIKE-14) — not a placeholder.
//
// SPIKE-14 already resolved the source (Protomaps Basemap, ODbL), the
// package (`vector_map_tiles` + `vector_tile_renderer`), the extraction
// tool (`pmtiles extract`, vendored at `spikes/SPIKE-14/tools/pmtiles`),
// and the label fix (a Plotlines-authored theme, D24) — and left a real
// extracted archive for the SPIKE-00 fixture region at
// `spikes/SPIKE-14/tiles/boulder.pmtiles`. What hadn't happened was reading
// it from the running client.
//
// `vector_map_tiles` 9.0.0-beta.11 can't resolve alongside a working
// `pmtiles` Dart package (SPIKE-14's harness doc comment, `main.dart`), so
// this — like that harness — reads decompressed `.mvt` files off a
// directory tree rather than the `.pmtiles` archive directly in-process.
// `assets/tiles/{z}/{x}/{y}.mvt` (496 files, ~9.2 MB, covering Boulder at
// z0-15) was exploded from the archive once with the vendored `pmtiles`
// CLI + gzip — see `spikes/SPIKE-14/tools/README.md` for that tool.
//
// Resolved the same way `SidecarManager` resolves the sidecar binary and
// cache dir: a bundled path beside the executable for the eventual real
// build (not populated yet — same open TODO as the sidecar binary, ARCH
// §12.2), falling back to the repo-relative source tree for `flutter run`.
// Only Boulder is covered; panning outside its bbox legitimately shows no
// tiles, which `TapToPickMap` states rather than hides.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:vector_map_tiles/vector_map_tiles.dart';

/// Mirrors `SidecarManager._resolveCacheDir`'s walk-up-from-cwd dev fallback
/// (`client/lib/data/sidecar_manager.dart`) — same reasoning, same limit.
Directory? resolveTilesRoot() {
  final exeDir = File(Platform.resolvedExecutable).parent;
  final bundled = Directory('${exeDir.path}/tiles');
  if (bundled.existsSync()) return bundled;

  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/client/assets/tiles');
    if (candidate.existsSync()) return candidate;
    final candidateFromClient = Directory('${dir.path}/assets/tiles');
    if (candidateFromClient.existsSync()) return candidateFromClient;
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  return null;
}

/// Serves decompressed MVT tiles from a local directory. Ported from
/// SPIKE-14's `DirectoryVectorTileProvider` (`spikes/SPIKE-14/harness/lib/main.dart`)
/// — same shape, deliberately: that implementation is what the spike
/// actually measured framerate against.
class DirectoryVectorTileProvider extends VectorTileProvider {
  DirectoryVectorTileProvider(this.root, {this.minimumZoom = 0, this.maximumZoom = 15});

  final Directory root;

  @override
  final int minimumZoom;

  @override
  final int maximumZoom;

  @override
  TileProviderType get type => TileProviderType.vector;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  int reads = 0;
  int misses = 0;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final f = File('${root.path}/${tile.z}/${tile.x}/${tile.y}.mvt');
    if (!await f.exists()) {
      misses++;
      throw ProviderException(
        message: 'tile not on disk: ${tile.z}/${tile.x}/${tile.y}',
        retryable: Retryable.none,
        statusCode: 404,
      );
    }
    reads++;
    return f.readAsBytes();
  }
}

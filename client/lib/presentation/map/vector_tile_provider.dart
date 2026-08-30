// Real basemap tiles (ARCH D22/D23/D24, SPIKE-14) — not a placeholder.
//
// Before #154, the client read decompressed `.mvt` files straight off a
// directory tree exploded from a Boulder-only PMTiles archive
// (`client/assets/tiles/`, 496 loose files, deliberately excluded from
// `pubspec.yaml`'s asset bundle because Flutter has no recursive asset
// globbing for a tree that size) — a real basemap for one ~20 km box and
// nothing else, and never actually reachable through the sidecar (FR92:
// "the client talks only to Plotlines' own tile service"). This now talks
// to the sidecar's `GET /tiles/{z}/{x}/{y}` (ARCH §8.2) instead, backed
// server-side by the committed home-region archive plus each ensured trip's
// own on-demand cache (`core/plotlines_core/tiles/`).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' show VectorTileReader;

/// Reads tiles from the sidecar rather than local disk. `baseUrl` is the
/// same `SidecarManager.baseUrl` every other client (`RoutingClient`,
/// `CurationClient`) talks to — constructed fresh per build rather than
/// cached, since the sidecar's port can change across a restart
/// (`SidecarManager._onExit`'s restart-once) and this class holds no state
/// expensive enough to be worth caching around that.
class SidecarVectorTileProvider extends VectorTileProvider {
  SidecarVectorTileProvider(this.baseUrl, {this.minimumZoom = 0, this.maximumZoom = 15});

  final String baseUrl;

  @override
  final int minimumZoom;

  @override
  final int maximumZoom;

  @override
  TileProviderType get type => TileProviderType.vector;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final uri = Uri.parse('$baseUrl/tiles/${tile.z}/${tile.x}/${tile.y}');
    final http.Response resp;
    try {
      resp = await http.get(uri).timeout(const Duration(seconds: 10));
    } catch (e) {
      throw ProviderException(
        message: 'sidecar unreachable for tile ${tile.z}/${tile.x}/${tile.y}: $e',
        retryable: Retryable.retry,
      );
    }
    if (resp.statusCode == 404) {
      throw ProviderException(
        message: 'no basemap tile at ${tile.z}/${tile.x}/${tile.y}',
        retryable: Retryable.none,
        statusCode: 404,
      );
    }
    if (resp.statusCode != 200) {
      throw ProviderException(
        message: 'sidecar returned ${resp.statusCode} for tile ${tile.z}/${tile.x}/${tile.y}',
        retryable: Retryable.retry,
        statusCode: resp.statusCode,
      );
    }
    final bytes = resp.bodyBytes;
    // Issue #155: a 200 that decodes to a tile with no features at all is
    // almost always a transient gap — the sidecar not yet warmed up, or the
    // archive briefly having nothing for this address. `VectorTileLayer`'s
    // raster mode renders such a tile to a background-only PNG and freezes
    // it on disk for a 30-day TTL, so a moment's gap becomes a blank map
    // that survives restarts. Refuse it as retryable instead: nothing is
    // cached and the tile is re-fetched on the next visit. A genuinely
    // empty in-coverage tile is vanishingly rare here (the home region is
    // land) and costs only one more request when it happens.
    if (_isZeroFeatureTile(bytes)) {
      throw ProviderException(
        message: 'empty basemap tile at ${tile.z}/${tile.x}/${tile.y} — '
            'not caching a blank render; will re-attempt on the next visit',
        retryable: Retryable.retry,
      );
    }
    return bytes;
  }

  bool _isZeroFeatureTile(Uint8List bytes) {
    if (bytes.isEmpty) return true;
    try {
      final tile = VectorTileReader().read(bytes);
      return tile.layers.every((layer) => layer.features.isEmpty);
    } catch (_) {
      // Undecodable bytes are a different failure — let them through to the
      // renderer, which logs its own parse error. This guard fires only on a
      // cleanly-decoded tile that genuinely carries nothing to draw.
      return false;
    }
  }
}

/// The folder `VectorTileLayer` (raster mode) writes rendered PNG tiles to
/// (issue #155). Two defects this closes versus the package default of an
/// un-namespaced `<tmpdir>/.vector_map`:
///
///  * it lives under the app's own cache directory — scoped to Plotlines,
///    swept with the app's cache, not shared with every other process;
///  * the leaf folder is keyed by [archiveId] (`/health`'s
///    `capabilities.tiles.archive`), so replacing or re-extracting the
///    PMTiles archive lands renders in a fresh folder and the previous
///    archive's renders are deleted rather than served for the 30-day
///    image-cache TTL.
///
/// [archiveId] is null against an older sidecar that does not report it; the
/// cache then uses a single `unversioned` leaf — still app-namespaced and
/// still behind the zero-feature guard, just without archive-swap
/// invalidation.
Future<Directory> basemapTileCacheFolder({String? archiveId}) async {
  final root = Directory('${(await getApplicationCacheDirectory()).path}/basemap_tiles');
  final target = Directory('${root.path}/${basemapCacheLeaf(archiveId)}');
  await target.create(recursive: true);
  sweepStaleArchiveFolders(root, keep: target);
  return target;
}

/// The `VectorTileLayer.cacheFolder` callback, typed `dynamic` on purpose.
/// `vector_map_tiles` resolves its own `Directory` through a conditional
/// import; `flutter analyze` picks the web stub (`typedef Directory =
/// String`) even though every VM/AOT build uses `dart:io`, so a directly
/// typed callback trips a phantom `Future<String>` vs `Future<Directory>`
/// mismatch at the call site. Passing it through a `dynamic` slot sidesteps
/// that without loosening the real contract — [basemapTileCacheFolder]
/// always returns a genuine `dart:io` `Directory`, which is exactly what the
/// io build of the package expects.
dynamic basemapCacheFolderCallback(String? archiveId) =>
    () => basemapTileCacheFolder(archiveId: archiveId);

/// The per-archive leaf folder name (issue #155). Sanitised to the same
/// `[a-zA-Z0-9.-]` set `StorageImageCache` already restricts its own keys to;
/// null/empty (an older sidecar not reporting `capabilities.tiles.archive`)
/// collapses to a single `unversioned` bucket.
String basemapCacheLeaf(String? archiveId) => (archiveId == null || archiveId.isEmpty)
    ? 'unversioned'
    : archiveId.replaceAll(RegExp('[^a-zA-Z0-9.-]'), '-');

/// Deletes every sibling under [root] except [keep] — renders derived from a
/// now-superseded archive (issue #155). Best-effort: a directory held open
/// (Windows) is simply swept on a later launch rather than raising here.
void sweepStaleArchiveFolders(Directory root, {required Directory keep}) {
  if (!root.existsSync()) return;
  for (final entry in root.listSync()) {
    if (entry is Directory && entry.path != keep.path) {
      try {
        entry.deleteSync(recursive: true);
      } catch (_) {
        // Best-effort — retried next launch.
      }
    }
  }
}

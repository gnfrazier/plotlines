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

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:vector_map_tiles/vector_map_tiles.dart';

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
    return resp.bodyBytes;
  }
}

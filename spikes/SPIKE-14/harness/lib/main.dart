// SPIKE-14 rendering harness.
//
// Answers the measurable half of the spike question: can a Flutter *desktop* client
// draw a real routed polyline with node markers over a vector basemap held locally,
// with the network unplugged, at an acceptable frame rate?
//
// This is deliberately not a pretty app. It renders one map, drives a scripted
// pan/zoom, records every frame's build+raster time via `addTimingsCallback`, writes
// a PNG so the result is checkable by eye, and prints JSON to stdout. Scripting the
// camera rather than dragging by hand is what makes two runs comparable — a human
// drag is a different workload every time.
//
// Run it in profile mode. `vector_map_tiles` disables its isolate concurrency in
// debug builds, so debug frame times measure a configuration we would never ship.
//
// Tiles are read from an exploded `assets/tiles/{z}/{x}/{y}.mvt` directory rather
// than from the PMTiles archive they came from. That is not the shipping design — it
// is forced. The `pmtiles` Dart package cannot be resolved alongside the only
// `vector_map_tiles` line that supports current `flutter_map`, so reading the archive
// in-process and rendering with a current renderer are, today, mutually exclusive.
// Splitting them here isolates the rendering question from the packaging question so
// each gets a real answer instead of one blocked answer. See RESULTS.md.
//
// Configured by environment variable so one binary covers every cell of the matrix:
//   SPIKE14_PAYLOAD  day | multi | stress   (route size)
//   SPIKE14_BASEMAP  vector | none          (basemap on or off, to attribute cost)
//   SPIKE14_THEME    light | dark
//   SPIKE14_ZOOM     initial zoom
//   SPIKE14_SECONDS  benchmark duration after warm-up
//   SPIKE14_SHOT     path to write a PNG capture

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

// Deliberately mutable and set as the first statement of `main`. A top-level
// `final` is lazily initialized on first *access* in Dart, so the obvious
// `final _t0 = DateTime.now()` starts the clock when the first frame reads it and
// reports a cold-open time of ~0 ms. That bug was in this harness's first run.
late DateTime _t0;

String _env(String k, String fallback) {
  final v = Platform.environment[k];
  return (v == null || v.isEmpty) ? fallback : v;
}

/// Serves decompressed MVT tiles from a local directory.
///
/// Deliberately dependency-free: it exists to prove the *renderer* works on desktop
/// without dragging in the archive reader that currently blocks the resolve.
class DirectoryVectorTileProvider extends VectorTileProvider {
  DirectoryVectorTileProvider(this.root,
      {this.minimumZoom = 8, this.maximumZoom = 15});

  final String root;

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
    final f = File('$root/${tile.z}/${tile.x}/${tile.y}.mvt');
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

Future<void> main() async {
  _t0 = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();

  final payload = _env('SPIKE14_PAYLOAD', 'day');
  final basemap = _env('SPIKE14_BASEMAP', 'vector');
  final themeName = _env('SPIKE14_THEME', 'light');
  final seconds = int.parse(_env('SPIKE14_SECONDS', '12'));

  final geo =
      jsonDecode(await File('assets/route_$payload.geojson').readAsString())
          as Map<String, dynamic>;

  final points = <LatLng>[];
  final markers = <LatLng>[];
  for (final f in (geo['features'] as List).cast<Map<String, dynamic>>()) {
    final g = f['geometry'] as Map<String, dynamic>;
    if (g['type'] == 'LineString') {
      for (final c in (g['coordinates'] as List)) {
        points.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
      }
    } else if (g['type'] == 'Point') {
      final c = g['coordinates'] as List;
      markers.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
    }
  }

  // Theme parse is timed on its own: it is a one-off startup cost of a few hundred
  // style rules, and lumping it into first-paint would misattribute it to tiles.
  Theme? theme;
  DirectoryVectorTileProvider? provider;
  var themeParseMs = 0.0;
  String? setupError;
  if (basemap == 'vector') {
    try {
      final sw = Stopwatch()..start();
      final styleJson = jsonDecode(
        await File('assets/style_$themeName.json').readAsString(),
      ) as Map<String, dynamic>;
      theme = ThemeReader(logger: const Logger.console()).read(styleJson);
      themeParseMs = sw.elapsedMicroseconds / 1000.0;
      provider = DirectoryVectorTileProvider('assets/tiles');
    } catch (e) {
      setupError = e.toString();
    }
  }

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: HarnessMap(
      points: points,
      markers: markers,
      theme: theme,
      provider: provider,
      setupError: setupError,
      themeParseMs: themeParseMs,
      payload: payload,
      basemap: basemap,
      themeName: themeName,
      seconds: seconds,
    ),
  ));
}

class HarnessMap extends StatefulWidget {
  const HarnessMap({
    super.key,
    required this.points,
    required this.markers,
    required this.theme,
    required this.provider,
    required this.setupError,
    required this.themeParseMs,
    required this.payload,
    required this.basemap,
    required this.themeName,
    required this.seconds,
  });

  final List<LatLng> points;
  final List<LatLng> markers;
  final Theme? theme;
  final DirectoryVectorTileProvider? provider;
  final String? setupError;
  final double themeParseMs;
  final String payload;
  final String basemap;
  final String themeName;
  final int seconds;

  @override
  State<HarnessMap> createState() => _HarnessMapState();
}

class _HarnessMapState extends State<HarnessMap> {
  final _controller = MapController();
  final _captureKey = GlobalKey();
  final _build = <int>[];
  final _raster = <int>[];
  final _total = <int>[];

  double? _firstFrameMs;
  bool _recording = false;
  Timer? _driver;
  late final LatLng _centre;
  late final double _spanDeg;
  late final double _zoom;

  @override
  void initState() {
    super.initState();
    _zoom = double.parse(_env('SPIKE14_ZOOM', '13'));

    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in widget.points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    _centre = LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
    _spanDeg = math.max(maxLat - minLat, maxLon - minLon);

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _firstFrameMs ??= DateTime.now().difference(_t0).inMicroseconds / 1000.0;
      Timer(const Duration(seconds: 5), () async {
        // A frame-time number cannot tell the difference between "drew the map" and
        // "drew an empty grey rectangle very quickly". Capturing real pixels is what
        // makes the rendering claim checkable afterwards.
        await _capture();
        _startBenchmark();
      });
    });
  }

  Future<void> _capture() async {
    final shot = _env('SPIKE14_SHOT', '');
    if (shot.isEmpty) return;
    try {
      final boundary = _captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      await File(shot).writeAsBytes(bytes!.buffer.asUint8List());
    } catch (e) {
      stdout.writeln('SPIKE14_CAPTURE_ERROR $e');
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_recording) return;
    for (final t in timings) {
      _build.add(t.buildDuration.inMicroseconds);
      _raster.add(t.rasterDuration.inMicroseconds);
      _total.add(t.totalSpan.inMicroseconds);
    }
  }

  void _startBenchmark() {
    _recording = true;
    var tick = 0;

    // A scripted orbit-and-zoom. Panning across the route while cycling zoom is what
    // an Author actually does while placing Nodes, and it forces continuous tile
    // substitution rather than sitting on one warm viewport.
    _driver = Timer.periodic(const Duration(milliseconds: 16), (t) {
      tick++;
      final phase = tick / 60.0;
      final r = _spanDeg * 0.35;
      _controller.move(
        LatLng(
          _centre.latitude + r * math.sin(phase),
          _centre.longitude + r * math.cos(phase),
        ),
        _zoom + 1.5 * math.sin(phase / 2),
      );
      if (tick >= widget.seconds * 62) {
        t.cancel();
        _finish();
      }
    });
  }

  double _pct(List<int> xs, double p) {
    if (xs.isEmpty) return 0;
    final s = [...xs]..sort();
    return s[(s.length * p).clamp(0, s.length - 1).floor()] / 1000.0;
  }

  void _finish() {
    _recording = false;
    // 16.7 ms is the 60 Hz budget. Counting frames over budget is the number that
    // corresponds to visible stutter, which a mean frame time hides completely.
    final janky = _total.where((t) => t > 16700).length;
    final result = {
      'payload': widget.payload,
      'basemap': widget.basemap,
      'theme': widget.themeName,
      'zoom': _zoom,
      'vertices': widget.points.length,
      'markers': widget.markers.length,
      'setup_error': widget.setupError,
      'theme_parse_ms': double.parse(widget.themeParseMs.toStringAsFixed(1)),
      'first_frame_ms': double.parse((_firstFrameMs ?? 0).toStringAsFixed(1)),
      'tile_reads': widget.provider?.reads ?? 0,
      'tile_misses': widget.provider?.misses ?? 0,
      'frames': _total.length,
      'build_p50_ms': double.parse(_pct(_build, 0.50).toStringAsFixed(2)),
      'build_p95_ms': double.parse(_pct(_build, 0.95).toStringAsFixed(2)),
      'raster_p50_ms': double.parse(_pct(_raster, 0.50).toStringAsFixed(2)),
      'raster_p95_ms': double.parse(_pct(_raster, 0.95).toStringAsFixed(2)),
      'total_p50_ms': double.parse(_pct(_total, 0.50).toStringAsFixed(2)),
      'total_p95_ms': double.parse(_pct(_total, 0.95).toStringAsFixed(2)),
      'total_p99_ms': double.parse(_pct(_total, 0.99).toStringAsFixed(2)),
      'fps_p50': double.parse(
          (_pct(_total, 0.50) == 0 ? 0 : 1000.0 / _pct(_total, 0.50))
              .toStringAsFixed(1)),
      'frames_over_16_7ms': janky,
      'jank_frac': double.parse(
          (_total.isEmpty ? 0 : janky / _total.length).toStringAsFixed(4)),
      'rss_kb': _rssKb(),
    };
    stdout.writeln('SPIKE14_RESULT ${jsonEncode(result)}');
    stdout.flush().then((_) => exit(0));
  }

  int _rssKb() {
    try {
      for (final l in File('/proc/self/status').readAsLinesSync()) {
        if (l.startsWith('VmRSS:')) {
          return int.parse(l.replaceAll(RegExp(r'[^0-9]'), ''));
        }
      }
    } catch (_) {}
    return 0;
  }

  @override
  void dispose() {
    _driver?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layers = <Widget>[];

    if (widget.theme != null && widget.provider != null) {
      layers.add(
        VectorTileLayer(
          theme: widget.theme!,
          tileProviders: TileProviders({'protomaps': widget.provider!}),
          maximumZoom: 15,
          concurrency: int.parse(_env('SPIKE14_CONCURRENCY', '2')),
        ),
      );
    }

    layers.add(PolylineLayer(
      polylines: [
        Polyline(
          points: widget.points,
          strokeWidth: 4.0,
          color: const Color(0xFFD4622A),
        ),
      ],
    ));

    layers.add(MarkerLayer(
      markers: [
        for (final m in widget.markers)
          Marker(
            point: m,
            width: 18,
            height: 18,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF1B4D3E),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    ));

    return Scaffold(
      body: RepaintBoundary(
        key: _captureKey,
        child: FlutterMap(
          mapController: _controller,
          options: MapOptions(initialCenter: _centre, initialZoom: _zoom),
          children: layers,
        ),
      ),
    );
  }
}

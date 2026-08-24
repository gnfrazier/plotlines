// N1 (PRD FR120) — the trip's bbox-drawing map, matching
// `client/design/Flow 1 - Trip initiation.dc.html` §04 and `Flow 9 -
// Editing and cascades.dc.html` §03: drag to draw a rectangle, corner
// handles to revise it afterward, a scale indication, and a recenter
// affordance so the map stays navigable while the extent is declared.
//
// Shares `MapTileAssets`/`MapGraticule` with `tap_to_pick_map.dart` rather
// than reloading the vector style/tile provider a second time.
//
// A **controlled** widget: [bbox] is the authoritative value, owned by the
// caller. Every gesture here only *proposes* a new value via
// [onProposeChange] — nothing here decides whether a proposal is accepted
// (that's the shrink-prompt check in `trip_bbox_shrink_prompt.dart`), so a
// rejected proposal simply doesn't change [bbox] and the next build snaps
// any live drag preview back to the last accepted value.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/material.dart' as material show Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../domain/trip_bbox.dart';
import 'tap_to_pick_map.dart' show MapGraticule, MapTileAssets;
import 'vector_tile_provider.dart';

enum _Corner { nw, ne, se, sw }

class TripAreaMap extends StatefulWidget {
  const TripAreaMap({
    super.key,
    required this.center,
    this.initialZoom = 10,
    required this.bbox,
    required this.drawing,
    required this.onProposeChange,
  });

  final LatLon center;
  final double initialZoom;

  /// The committed extent, or null before anything has been drawn.
  final TripBbox? bbox;

  /// Whether a drag on the map surface draws a new rectangle. When false,
  /// an existing [bbox] instead shows draggable corner handles.
  final bool drawing;

  final ValueChanged<TripBbox> onProposeChange;

  @override
  State<TripAreaMap> createState() => TripAreaMapState();
}

class TripAreaMapState extends State<TripAreaMap> {
  final _mapController = MapController();
  final _mapAreaKey = GlobalKey();

  Offset? _drawStartGlobal;
  Offset? _drawCurrentGlobal;
  TripBbox? _liveResize;

  /// `MapController.camera` throws until `FlutterMap` has completed its
  /// first layout — screen-offset-dependent overlays (corner handles, the
  /// scale bar) wait for `MapOptions.onMapReady` rather than racing it on
  /// the very first build.
  bool _mapReady = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TripAreaMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.drawing) {
      _drawStartGlobal = null;
      _drawCurrentGlobal = null;
    }
  }

  /// FR120 — "recentre on the prompt's location." Zoom is left as-is: only
  /// the center should snap back, not whatever framing the Author chose.
  void recenter() =>
      _mapController.move(ll.LatLng(widget.center[1], widget.center[0]), _mapController.camera.zoom);

  LatLon _globalToLatLon(Offset global) {
    final box = _mapAreaKey.currentContext!.findRenderObject() as RenderBox;
    final local = box.globalToLocal(global);
    final p = _mapController.camera.screenOffsetToLatLng(local);
    return [p.longitude, p.latitude];
  }

  Offset _latLonToOffset(LatLon p) =>
      _mapController.camera.latLngToScreenOffset(ll.LatLng(p[1], p[0]));

  // Raw `Listener` pointer events, not `GestureDetector`/`onPan*`: a
  // `PanGestureRecognizer` here would enter the same gesture arena as
  // FlutterMap's own internal scale/pan recognizer and reliably lose it
  // (both are drag-family recognizers competing for the same pointer), so
  // `onPanStart` never fires even with panning disabled via
  // `InteractionOptions`. Raw pointer events bypass arena negotiation
  // entirely and always reach us.
  int? _drawPointer;

  void _onPointerDown(PointerDownEvent e) {
    if (!widget.drawing) return;
    setState(() {
      _drawPointer = e.pointer;
      _drawStartGlobal = e.position;
      _drawCurrentGlobal = e.position;
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_drawPointer != e.pointer) return;
    setState(() => _drawCurrentGlobal = e.position);
  }

  void _onPointerUp(PointerEvent e) {
    if (_drawPointer != e.pointer || _drawStartGlobal == null || _drawCurrentGlobal == null) return;
    final a = _globalToLatLon(_drawStartGlobal!);
    final b = _globalToLatLon(_drawCurrentGlobal!);
    setState(() {
      _drawPointer = null;
      _drawStartGlobal = null;
      _drawCurrentGlobal = null;
    });
    // A drag with no real extent (a tap, not a draw) proposes nothing.
    if (a[0] == b[0] || a[1] == b[1]) return;
    widget.onProposeChange(TripBbox.fromCorners(a, b));
  }

  int? _resizePointer;
  _Corner? _resizeCorner;

  void _onCornerPointerDown(_Corner corner, PointerDownEvent e) {
    setState(() {
      _resizePointer = e.pointer;
      _resizeCorner = corner;
      _liveResize = widget.bbox;
    });
  }

  void _onCornerPointerMove(PointerMoveEvent e) {
    final corner = _resizeCorner;
    final base = _liveResize ?? widget.bbox;
    if (_resizePointer != e.pointer || corner == null || base == null) return;
    final p = _globalToLatLon(e.position);
    final next = switch (corner) {
      _Corner.nw => base.copyWith(maxLat: p[1], minLon: p[0]),
      _Corner.ne => base.copyWith(maxLat: p[1], maxLon: p[0]),
      _Corner.se => base.copyWith(minLat: p[1], maxLon: p[0]),
      _Corner.sw => base.copyWith(minLat: p[1], minLon: p[0]),
    };
    setState(() => _liveResize = next);
  }

  void _onCornerPointerUp(PointerEvent e) {
    if (_resizePointer != e.pointer) return;
    final result = _liveResize;
    setState(() {
      _resizePointer = null;
      _resizeCorner = null;
      _liveResize = null;
    });
    if (result != null) widget.onProposeChange(result);
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final displayBbox = _liveResize ?? widget.bbox;
    final drawPreview = (_drawStartGlobal != null && _drawCurrentGlobal != null)
        ? TripBbox.fromCorners(_globalToLatLon(_drawStartGlobal!), _globalToLatLon(_drawCurrentGlobal!))
        : null;
    final backdrop = drawPreview ?? displayBbox;

    return FutureBuilder(
      future: Future.wait([MapTileAssets.theme(isDark ? 'dark' : 'light'), MapTileAssets.provider()]),
      builder: (context, snapshot) {
        final results = snapshot.data;
        final vectorTheme = results?[0] as Theme?;
        final provider = results?[1] as DirectoryVectorTileProvider?;
        final tilesAvailable = vectorTheme != null && provider != null;

        // Navigating never alters the extent (FR120): panning is its own
        // gesture, so it's suspended only while a drag *is* the draw
        // gesture or is actively resizing a corner — zoom stays available
        // either way ("the map is navigable while the extent is drawn").
        final dragSuspended = widget.drawing || _resizePointer != null;

        return Stack(
          key: _mapAreaKey,
          children: [
            Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerUp,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: ll.LatLng(widget.center[1], widget.center[0]),
                  initialZoom: widget.initialZoom,
                  interactionOptions: InteractionOptions(
                    flags: dragSuspended
                        ? InteractiveFlag.pinchZoom |
                            InteractiveFlag.scrollWheelZoom |
                            InteractiveFlag.doubleTapZoom
                        : InteractiveFlag.all,
                  ),
                  onMapEvent: (_) => setState(() {}), // reposition handles/scale bar
                  onMapReady: () => setState(() => _mapReady = true),
                ),
                children: [
                  if (tilesAvailable)
                    VectorTileLayer(
                      theme: vectorTheme,
                      tileProviders: TileProviders({'protomaps': provider}),
                      maximumZoom: 15,
                    )
                  else
                    MapGraticule(color: c.border),
                  if (backdrop != null)
                    PolygonLayer(polygons: [
                      Polygon(
                        points: [for (final p in backdrop.outline) ll.LatLng(p[1], p[0])],
                        color: c.primary.withValues(alpha: 0.07),
                        borderColor: c.primary,
                        borderStrokeWidth: 2,
                      ),
                    ]),
                ],
              ),
            ),
            if (!tilesAvailable)
              Positioned(
                left: PlotSpacing.s3,
                bottom: PlotSpacing.s3,
                child: _NoBasemapNotice(loading: snapshot.connectionState != ConnectionState.done),
              ),
            if (_mapReady && displayBbox != null && !widget.drawing)
              for (final corner in _Corner.values) _cornerHandle(context, corner, displayBbox),
            if (_mapReady)
              Positioned(
                  right: PlotSpacing.s3, bottom: PlotSpacing.s3, child: _ScaleBar(_mapController)),
            Positioned(
              right: PlotSpacing.s3,
              top: PlotSpacing.s3,
              child: _MapButton(icon: Icons.center_focus_strong, tooltip: 'Recenter', onPressed: recenter),
            ),
          ],
        );
      },
    );
  }

  Widget _cornerHandle(BuildContext context, _Corner corner, TripBbox box) {
    final c = PlotColors.of(context);
    final point = switch (corner) {
      _Corner.nw => [box.minLon, box.maxLat],
      _Corner.ne => [box.maxLon, box.maxLat],
      _Corner.se => [box.maxLon, box.minLat],
      _Corner.sw => [box.minLon, box.minLat],
    };
    final offset = _latLonToOffset(point);
    const size = 18.0;
    return Positioned(
      left: offset.dx - size / 2,
      top: offset.dy - size / 2,
      child: Listener(
        onPointerDown: (e) => _onCornerPointerDown(corner, e),
        onPointerMove: _onCornerPointerMove,
        onPointerUp: _onCornerPointerUp,
        onPointerCancel: _onCornerPointerUp,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: c.primary, width: 2),
              shape: BoxShape.rectangle,
            ),
          ),
        ),
      ),
    );
  }
}

/// FR120 — "with a scale indication so the Author can judge the extent's
/// real size." Standard rounded-length scale bar: picks a "nice" ground
/// distance near a target pixel width, then draws the bar at the pixel
/// width that distance actually occupies at the current zoom/latitude.
class _ScaleBar extends StatelessWidget {
  const _ScaleBar(this.controller);
  final MapController controller;

  static const _niceKm = [
    0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000,
  ];
  static const _targetPx = 90.0;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final camera = controller.camera;
    // Web Mercator meters-per-pixel at this zoom/latitude.
    final metersPerPixel =
        156543.03392 * math.cos(camera.center.latitudeInRad) / math.pow(2, camera.zoom);
    final targetKm = metersPerPixel * _targetPx / 1000;
    final niceKm = _niceKm.reduce(
      (a, b) => (a - targetKm).abs() < (b - targetKm).abs() ? a : b,
    );
    final widthPx = niceKm * 1000 / metersPerPixel;
    final label = niceKm >= 1 ? '${niceKm.toStringAsFixed(niceKm >= 10 ? 0 : 1)} KM' : '${(niceKm * 1000).round()} M';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: widthPx,
          height: 6,
          decoration: BoxDecoration(border: Border.all(color: c.textSecondary), color: c.surfaceCard.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: 2),
        Text(label, style: PlotTypography.data(c.textSecondary)),
      ],
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c.surfaceCard.withValues(alpha: 0.92),
        shape: const CircleBorder(side: BorderSide.none),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(PlotSpacing.s2),
            child: Icon(icon, size: 18, color: c.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _NoBasemapNotice extends StatelessWidget {
  const _NoBasemapNotice({required this.loading});
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.surfaceCard.withValues(alpha: 0.92),
        borderRadius: const BorderRadius.all(PlotRadii.md),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers_outlined, size: 14, color: c.textMuted),
          const SizedBox(width: PlotSpacing.s2),
          Text(
            loading ? 'Loading basemap…' : 'No basemap tiles here (Boulder, CO only)',
            style: PlotTypography.data(c.textMuted),
          ),
        ],
      ),
    );
  }
}

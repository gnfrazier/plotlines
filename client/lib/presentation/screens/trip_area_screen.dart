// N1 (PRD FR120, FR96) / Author Flows MVP Flow 1 "Draw the bbox" — step 2
// of trip initiation: after the location prompt centers the map
// (`trip_location_prompt.dart`), the Author draws the trip's bounding box
// here. Also the reachable path for revising it afterward (FR142(b)/K12 —
// "a new object type ships with its path named, or it does not ship"),
// opened from `trip_shell_screen.dart`'s app bar.
//
// Matches `client/design/Flow 1 - Trip initiation.dc.html` §04's structure
// (map + coordinate/extent side panel, Redraw / Use this extent) without
// reproducing its per-consumer size/time estimates (~40 S extraction, 318
// MB tiles, ...) — nothing in this codebase computes those yet, and
// inventing numbers would be the same eager-estimate dishonesty FR96
// already rejects for the old first-run download.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/home_region.dart' hide LatLon;
import '../../domain/trip_bbox.dart';
import '../../state/current_trip_provider.dart';
import '../../state/settings_provider.dart';
import '../../state/trip_bbox_provider.dart';
import '../map/trip_area_map.dart';
import '../widgets/trip_bbox_shrink_prompt.dart';

class TripAreaScreen extends ConsumerStatefulWidget {
  const TripAreaScreen({
    super.key,
    this.initialCenter,
    this.initialFramingBbox,
    required this.isCreation,
  });

  /// Where the trip-creation location prompt resolved to (A10). Centers the
  /// map only. Null means the Author chose the shipped home region, or this
  /// is a revision (which frames on the existing bbox instead).
  final LatLon? initialCenter;

  /// Nominatim's bounding geometry for [initialCenter] (issue #154), `[west,
  /// south, east, north]` — frames the draw map's initial camera so the
  /// Author isn't declaring the bbox at an arbitrary zoom (FR120). **Never
  /// becomes the trip bbox** — it only ever feeds the map's initial camera
  /// fit, the same way [initialCenter] only ever centers it.
  final List<double>? initialFramingBbox;

  /// True for trip initiation (trip_library_screen.dart, right after the
  /// location prompt); false when reached as a later revision
  /// (trip_shell_screen.dart's app bar). **Not inferred from whether a bbox
  /// is already set**: the bbox is session-only (trip_bbox_provider.dart)
  /// and resets when a saved trip is reopened, so "no bbox yet" doesn't
  /// reliably mean "this is a brand-new trip."
  final bool isCreation;

  @override
  ConsumerState<TripAreaScreen> createState() => _TripAreaScreenState();
}

class _TripAreaScreenState extends ConsumerState<TripAreaScreen> {
  late final TripBbox? _startingBbox = ref.read(tripBboxProvider);
  late bool _drawing = _startingBbox == null;

  /// Frames the map: the existing extent's center when revising, otherwise
  /// wherever the location prompt resolved to (A10) — never both mixed.
  late final LatLon _center = _startingBbox?.center ?? widget.initialCenter ?? HomeRegion.center;

  /// FR120 — "the map is navigable while the extent is drawn," framed on
  /// the extent actually being drawn (issue #154): the existing bbox when
  /// revising, else the location prompt's geocoded bbox when starting
  /// fresh. Null (falls back to `_center`/`HomeRegion.previewZoom`) only
  /// when neither exists — the Author picked the shipped home region with
  /// no geocode result to frame on.
  CameraFit? get _initialCameraFit {
    final starting = _startingBbox;
    if (starting != null) {
      return CameraFit.bounds(
        bounds: LatLngBounds(
          ll.LatLng(starting.minLat, starting.minLon),
          ll.LatLng(starting.maxLat, starting.maxLon),
        ),
        padding: const EdgeInsets.all(48),
      );
    }
    final framing = widget.initialFramingBbox;
    if (framing == null) return null;
    return CameraFit.bounds(
      bounds: LatLngBounds(
        ll.LatLng(framing[1], framing[0]),
        ll.LatLng(framing[3], framing[2]),
      ),
      padding: const EdgeInsets.all(48),
    );
  }

  Future<void> _handleProposal(TripBbox proposed) async {
    await reviseTripBbox(
      context,
      proposed: proposed,
      anchors: ref.read(tripAnchorsProvider),
      onApply: (b) => ref.read(tripBboxProvider.notifier).set(b),
      onRemoveAnchors: (outside) => ref
          .read(currentTripProvider.notifier)
          .removeNodesById({for (final a in outside) a.id}),
    );
    if (mounted) setState(() => _drawing = false);
  }

  void _confirm() {
    if (widget.isCreation) {
      // Issue #154's second leak: this used to forward `widget.initialCenter`
      // (the geocode result) rather than what the Author actually drew.
      // Picking "Use Buncombe County, NC" yields `initialCenter: null`, so
      // New Route fell through to a hardcoded Boulder default. `bbox.center`
      // is always non-null here — the "Use this extent" button (below) is
      // itself disabled until a bbox exists.
      final bbox = ref.read(tripBboxProvider);
      context.push('/new', extra: bbox?.center);
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final bbox = ref.watch(tripBboxProvider);
    final unit = ref.watch(settingsProvider).unit;
    // FR120/D41, issue #154 — "the client sends the extent: tripBboxProvider
    // is read at trip initiation to ensure the region." Watching here (not
    // just at New Route, which needs the result) starts the graph/tile
    // build as soon as the Author accepts a bbox, not only once they reach
    // the next screen. `ensureRegion` is idempotent and cheap to call again
    // for a bbox already ensured, so this never duplicates work.
    ref.watch(tripRegionKeyProvider);

    return Scaffold(
      appBar: AppBar(
        // Issue #230 C1 — one dismiss idiom across the flow. This screen
        // used a `×` while New Route, one step later in the same flow, used
        // a `←`; both are a step back through trip creation, so both are a
        // back arrow, and both name what they do.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: widget.isCreation ? 'Back to the location prompt' : 'Back to the trip',
          onPressed: () => context.pop(),
        ),
        title: Text(widget.isCreation ? 'New trip · trip extent' : 'Trip extent'),
        actions: [
          // Issue #230 B1 — the mockups carry a step indicator on every
          // multi-step flow (`NEW TRIP · STEP 2 OF 2`); the shipped screen
          // gave no sense of where in trip creation the Author was.
          if (widget.isCreation)
            Padding(
              padding: const EdgeInsets.only(right: PlotSpacing.s4),
              child: Center(
                child: Text('NEW TRIP · STEP 2 OF 3',
                    style: PlotTypography.eyebrow(c.textMuted)),
              ),
            ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: TripAreaMap(
              center: _center,
              initialCameraFit: _initialCameraFit,
              bbox: bbox,
              drawing: _drawing,
              onProposeChange: _handleProposal,
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          SizedBox(
            width: 376,
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                        PlotSpacing.s5, PlotSpacing.s5, PlotSpacing.s5, PlotSpacing.s3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('TRIP EXTENT', style: PlotTypography.eyebrow(c.textMuted)),
                        const SizedBox(height: PlotSpacing.s2),
                        Text('Draw the bounding box', style: PlotTypography.title(c.textPrimary)),
                        const SizedBox(height: PlotSpacing.s2),
                        Text(
                          'Zoom and pan until you can see the whole area, then drag a rectangle '
                          'around everything the trip might touch — including the drive in and '
                          'any bail-out you might want.',
                          style: PlotTypography.body(c.textSecondary),
                        ),
                        const SizedBox(height: PlotSpacing.s4),
                        // Issue #230 C1 — this was two near-identically
                        // styled tip cards, the second re-reassuring what the
                        // first already said ("generous beats tight; drawing
                        // it does not commit you" / "you are not locked in").
                        // One block, both facts, before the first control.
                        PlotCard(
                          sunk: true,
                          child: Text(
                            'This rectangle is the only area Plotlines looks at — for places, '
                            'for maps, and for terrain. Generous beats tight, and you are not '
                            'locked in: drag it wider later and only the new strip gets '
                            'fetched; pull it in and you are shown any anchors that would fall '
                            'outside before anything changes.',
                            style: PlotTypography.body(c.textSecondary),
                          ),
                        ),
                        if (bbox != null) ...[
                          const SizedBox(height: PlotSpacing.s5),
                          _ExtentReadout(bbox: bbox, unit: unit),
                        ],
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(PlotSpacing.s5),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Issue #230 C1 — Flow 8's pattern is "disabled and
                      // says so". "Use this extent" was a light-tan-on-tan
                      // control with nothing stating why it would not act.
                      if (bbox == null) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.crop_free, size: 15, color: c.textMuted),
                            const SizedBox(width: PlotSpacing.s2),
                            Expanded(
                              child: Text(
                                'Drag a rectangle on the map to set the extent — nothing to '
                                'use yet.',
                                style: PlotTypography.small(c.textSecondary),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: PlotSpacing.s3),
                      ],
                      Row(
                        children: [
                          if (bbox != null) ...[
                            PlotButton(
                              label: 'Redraw',
                              variant: PlotButtonVariant.secondary,
                              onPressed: () => setState(() => _drawing = true),
                            ),
                            const SizedBox(width: PlotSpacing.s3),
                          ],
                          Expanded(
                            child: PlotButton(
                              label: 'Use this extent',
                              expand: true,
                              onPressed: bbox == null ? null : _confirm,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExtentReadout extends StatelessWidget {
  const _ExtentReadout({required this.bbox, required this.unit});
  final TripBbox bbox;
  final DistanceUnit unit;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final miles = unit == DistanceUnit.miles;
    final w = miles ? bbox.widthKm * 0.621371 : bbox.widthKm;
    final h = miles ? bbox.heightKm * 0.621371 : bbox.heightKm;
    final suffix = miles ? 'MI' : 'KM';

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: PlotTypography.data(c.textMuted)),
              Text(value, style: PlotTypography.data(c.textSecondary)),
            ],
          ),
        );

    // Issue #230 C1 — the area is the number a human decides on; four
    // 4-decimal-place coordinates set at the same size and weight as their
    // own labels buried it. Area leads, at a size that reads across the
    // room; the raw decimal degrees stay (they are the real declared
    // extent) but sit under a collapsed "exact bounds" disclosure, in the
    // secondary tone, where a developer or a careful Author can open them.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('AREA', style: PlotTypography.eyebrow(c.textMuted)),
        const SizedBox(height: 2),
        Text(
          '${w.toStringAsFixed(1)} × ${h.toStringAsFixed(1)} $suffix',
          style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 24, height: 1.15),
        ),
        const SizedBox(height: PlotSpacing.s2),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: c.border),
            borderRadius: PlotRadii.controlShape,
          ),
          child: ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3),
            childrenPadding: const EdgeInsets.fromLTRB(
                PlotSpacing.s3, 0, PlotSpacing.s3, PlotSpacing.s3),
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('Exact bounds', style: PlotTypography.small(c.textSecondary)),
            children: [
              row('NORTH', bbox.maxLat.toStringAsFixed(4)),
              row('SOUTH', bbox.minLat.toStringAsFixed(4)),
              row('WEST', bbox.minLon.toStringAsFixed(4)),
              row('EAST', bbox.maxLon.toStringAsFixed(4)),
            ],
          ),
        ),
      ],
    );
  }
}

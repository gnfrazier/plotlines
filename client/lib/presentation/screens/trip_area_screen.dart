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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/home_region.dart' hide LatLon;
import '../../domain/trip_bbox.dart';
import '../../state/current_trip_provider.dart';
import '../../state/settings_provider.dart';
import '../../state/trip_bbox_provider.dart';
import '../map/trip_area_map.dart';
import '../widgets/trip_bbox_shrink_prompt.dart';

class TripAreaScreen extends ConsumerStatefulWidget {
  const TripAreaScreen({super.key, this.initialCenter, required this.isCreation});

  /// Where the trip-creation location prompt resolved to (A10). Centers the
  /// map only. Null means the Author chose the shipped home region, or this
  /// is a revision (which frames on the existing bbox instead).
  final LatLon? initialCenter;

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
      context.push('/new', extra: widget.initialCenter);
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final bbox = ref.watch(tripBboxProvider);
    final unit = ref.watch(settingsProvider).unit;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => context.pop()),
        title: Text(widget.isCreation ? 'New trip · trip extent' : 'Trip extent'),
      ),
      body: Row(
        children: [
          Expanded(
            child: TripAreaMap(
              center: _center,
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
                        Text('TRIP EXTENT',
                            style: PlotTypography.data(c.textMuted)
                                .copyWith(fontWeight: FontWeight.w700)),
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
                        PlotCard(
                          sunk: true,
                          child: Text(
                            'This rectangle is the only area Plotlines looks at — for places, '
                            'for maps, and for terrain. Generous beats tight; drawing it does '
                            'not commit you to riding all of it.',
                            style: PlotTypography.small(c.textSecondary),
                          ),
                        ),
                        const SizedBox(height: PlotSpacing.s5),
                        if (bbox != null) ...[
                          _ExtentReadout(bbox: bbox, unit: unit),
                          const SizedBox(height: PlotSpacing.s5),
                        ],
                        PlotCard(
                          sunk: true,
                          child: Text(
                            'You are not locked in. Drag it wider later and only the new strip '
                            'gets fetched; pull it in and you are shown any anchors that would '
                            'fall outside before anything changes.',
                            style: PlotTypography.small(c.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(PlotSpacing.s5),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
                  child: Row(
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
              Text(value, style: PlotTypography.data(c.textPrimary)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('NORTH', bbox.maxLat.toStringAsFixed(4)),
        row('SOUTH', bbox.minLat.toStringAsFixed(4)),
        row('WEST', bbox.minLon.toStringAsFixed(4)),
        row('EAST', bbox.maxLon.toStringAsFixed(4)),
        Divider(color: c.border, height: PlotSpacing.s4),
        row('AREA', '${w.toStringAsFixed(1)} × ${h.toStringAsFixed(1)} $suffix'),
      ],
    );
  }
}

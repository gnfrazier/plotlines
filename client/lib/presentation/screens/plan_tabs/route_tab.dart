// Wireframe screen "01 Route Planner" — the Trip Shell's Route tab: the
// always-visible weights rail (`weights_rail.dart`), the map + day timeline
// strip (`day_timeline_strip.dart`), replacing the old standalone
// `route_planner_screen.dart` (deleted) which used a day/segment list
// instead of the wireframe's map-first canvas.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../data/sidecar_manager.dart' show CapabilityStatus;
import '../../../domain/domain.dart';
import '../../../state/planner_ui_state.dart';
import '../../../state/providers.dart';
import '../../../state/settings_provider.dart';
import '../../map/tap_to_pick_map.dart';
import '../../widgets/day_timeline_strip.dart';
import '../../widgets/metrics_rail.dart';
import '../../widgets/node_editor_sheet.dart';
import '../../widgets/weights_rail.dart';

/// Every day's segment endpoints, each tagged with the role it plays: a
/// segment's `start` begins a day, its `end` finishes one (#320). The mark is
/// chosen from that role, never from the point's position in a concatenated
/// list — so on a multi-day trip *every* day's start is a `start`, not just
/// day 1's, and a lone endpoint is not both the first and last index at once.
///
/// Authored `Segment.nodes` / `Day.nodes` are still not drawn here — that is
/// #322, which reuses the typed [MapMarkerPoint] shape this introduces.
List<MapMarkerPoint> routeTabMarkerPoints(Trip trip) => [
      for (final d in trip.days)
        for (final s in d.segments) ...[
          if (s.start != null)
            (coord: s.start!, role: NodeMarkerType.start),
          if (s.end != null) (coord: s.end!, role: NodeMarkerType.finish),
        ],
    ];

class RouteTab extends ConsumerStatefulWidget {
  const RouteTab({super.key, required this.trip, required this.activeDayId, required this.onSelectDay});
  final Trip trip;
  final String? activeDayId;
  final ValueChanged<String> onSelectDay;

  @override
  ConsumerState<RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends ConsumerState<RouteTab> {
  bool _addingNode = false;

  /// FR121/N2 — same "no trip-wide flag" reading `new_route_screen.dart`'s
  /// `_routingCapability` uses: before the sidecar has answered `/health`
  /// even once this is an honest wait, not a bare "not ready".
  CapabilityStatus get _elevationCapability =>
      ref.watch(sidecarManagerProvider).capabilities?.elevation ??
      const CapabilityStatus(ready: false, reason: 'waiting for the sidecar');

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final selected = ref.watch(selectedSegmentProvider);
    final selectedSegment = resolveSelectedSegment(widget.trip, selected)?.$2;
    final railDayId = selected?.$1 ?? widget.activeDayId ?? '';

    // E3 / FR39 / FR117 / FR118 (issue #214) — the compose-mode places-first
    // itinerary for the day the rail is showing, when that day is in compose
    // mode. `composeAuthoritative` fills the provider on save; it stays null in
    // explore mode and until the first authoritative pass.
    final composeItinerary =
        ref.watch(dayPlanningModeProvider(railDayId)) == PlanningMode.compose
            ? ref.watch(composeItineraryProvider(railDayId))
            : null;

    return Row(
      children: [
        WeightsRail(dayId: railDayId, segment: selectedSegment),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    TapToPickMap(
                      points: routeTabMarkerPoints(widget.trip),
                      polyline: selectedSegment?.geometry?.coordinates ?? const [],
                      onTap: (!_addingNode || selected == null)
                          ? null
                          : (point) {
                              showNodeEditorSheet(
                                context,
                                dayId: selected.$1,
                                segmentId: selected.$2,
                                coord: point,
                              );
                              setState(() => _addingNode = false);
                            },
                    ),
                    if (selected != null)
                      Positioned(
                        top: PlotSpacing.s3,
                        right: PlotSpacing.s3,
                        child: PlotButton(
                          label: _addingNode ? 'Tap map to place node…' : 'Add node',
                          icon: Icons.add_location_alt_outlined,
                          variant: _addingNode ? PlotButtonVariant.secondary : PlotButtonVariant.primary,
                          onPressed: () => setState(() => _addingNode = !_addingNode),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              DayTimelineStrip(
                trip: widget.trip,
                activeDayId: widget.activeDayId,
                onSelectDay: widget.onSelectDay,
              ),
            ],
          ),
        ),
        MetricsRail(
          trip: widget.trip,
          selectedSegment: selectedSegment,
          elevationCapability: _elevationCapability,
          composeItinerary: composeItinerary,
          displayFormat: ref.watch(displayFormatProvider),
        ),
      ],
    );
  }
}

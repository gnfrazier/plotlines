// Issue #640 — the one ROUTE THROUGH list: every point the passage's route
// must reach, in the order a solve visits them, and whether the solved line
// reached each one.
//
// Before this there were two lists with one name. The left rail's (#589) could
// be reordered but sat at the foot of Frame, which opens closed; the metrics
// rail's was the one an Author saw, and it only reported. An Author building a
// route from nodes (#626) found a list they could not change. This list lives
// where the old report did and does both jobs.
//
// Order rules (`domain/route_through.dart`): a start node is pinned first and
// a finish node last; every other routed point is the Author's to order by
// drag or by the arrows. Every change goes through `updateSegmentVia`, which
// re-pins the ends, marks the passage stale and keeps A9a's advisory in step.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';

class RouteThroughList extends ConsumerWidget {
  const RouteThroughList({
    super.key,
    required this.dayId,
    required this.segment,
    required this.anchors,
    required this.displayFormat,
  });

  final String dayId;
  final Segment segment;
  final List<Anchor> anchors;
  final DisplayFormat displayFormat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    // Compose orders its route through the spine editor (#589); here the list
    // only reports.
    final editable = ref.watch(dayPlanningModeProvider(dayId)) != PlanningMode.compose;
    final solved = (segment.geometry?.coordinates.length ?? 0) >= 2;
    final stale = segment.solve?.stale ?? false;
    final reach = viaReach(segment, anchors: anchors);
    final via = segment.via;

    void setVia(List<Coord> next) =>
        ref.read(currentTripProvider.notifier).updateSegmentVia(dayId, segment.id, next);
    void move(int from, int to) {
      final next = [...via];
      next.insert(to, next.removeAt(from));
      setVia(next);
    }

    bool pinned(int i) => viaPointIsPinned(segment, i);
    Node? nodeAt(int i) {
      for (final n in segment.nodes) {
        if (sameCoord(n.coord, via[i])) return n;
      }
      return null;
    }

    Widget row(int i) {
      final node = nodeAt(i);
      final isPinned = pinned(i);
      final tag = isPinned ? (node!.kind == NodeKind.start ? 'START' : 'FINISH') : null;
      // A via node routes through by what it is; it leaves the route by
      // changing its kind, not from here.
      final removable = !(node != null && nodeKindAlwaysRoutesThrough(node.kind));
      final r = reach[i];
      final canUp = i > 0 && !isPinned && !pinned(i - 1);
      final canDown = i < via.length - 1 && !isPinned && !pinned(i + 1);
      Widget control(String tooltip, IconData icon, VoidCallback? onPressed) => IconButton(
            tooltip: tooltip,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            icon: Icon(icon, size: 16),
            onPressed: onPressed,
          );

      return Padding(
        key: ValueKey('via-row-$i'),
        padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
        child: PlotCard(
          sunk: true,
          padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s2, vertical: PlotSpacing.s1),
          child: Row(
            children: [
              if (editable)
                isPinned
                    ? Tooltip(
                        message: tag == 'START'
                            ? 'The start is always first'
                            : 'The finish is always last',
                        child: Icon(Icons.lock_outline, size: 16, color: c.textMuted),
                      )
                    : ReorderableDragStartListener(
                        index: i,
                        // No tooltip here: its long-press would compete
                        // with the drag. The hint line above says it.
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Semantics(
                            label: 'Drag to reorder',
                            child: Icon(Icons.drag_indicator, size: 16, color: c.textMuted),
                          ),
                        ),
                      ),
              const SizedBox(width: PlotSpacing.s2),
              Text('${i + 1}', style: PlotTypography.data(c.textMuted)),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FR145 — the label (an Author's node title) stands
                    // alone; the tag and status beside it are fixed text.
                    Text(r.label, style: PlotTypography.small(c.textPrimary)),
                    if (tag != null) Text(tag, style: PlotTypography.data(c.textMuted)),
                    if (solved && !stale)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Icon(
                            r.reached ? Icons.check : Icons.warning_amber_rounded,
                            size: 12,
                            color: r.reached ? c.textSecondary : c.warning,
                          ),
                          const SizedBox(width: PlotSpacing.s1),
                          Text(
                            r.reached ? 'reached' : 'missed',
                            style: PlotTypography.small(
                                r.reached ? c.textSecondary : c.textPrimary),
                          ),
                          if (!r.reached && r.offsetM != null) ...[
                            const SizedBox(width: PlotSpacing.s1),
                            Text(displayFormat.formatDistance(r.offsetM!),
                                style: PlotTypography.data(c.textSecondary)),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
              if (editable && !isPinned) ...[
                control('Move earlier', Icons.arrow_upward, canUp ? () => move(i, i - 1) : null),
                control('Move later', Icons.arrow_downward,
                    canDown ? () => move(i, i + 1) : null),
                if (removable)
                  control('Stop routing through this', Icons.close,
                      () => setVia([...via]..removeAt(i))),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (editable && via.length > 1) ...[
          Text(
            'Drag or use the arrows to set the order. A start and a finish stay at the ends.',
            key: const ValueKey('via-order-hint'),
            style: PlotTypography.small(c.textMuted),
          ),
          const SizedBox(height: PlotSpacing.s2),
        ],
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (from, to) => move(from, to > from ? to - 1 : to),
          children: [for (var i = 0; i < via.length; i++) row(i)],
        ),
        if (!solved || stale)
          Text(
            !solved
                ? 'Not solved yet. Generate the route to check it reaches these.'
                : 'Changed since the last solve. Re-solve to check the route reaches these.',
            key: const ValueKey('via-reach-pending'),
            style: PlotTypography.small(c.textMuted),
          ),
        // A9a / FR8a — three or more points fix the route's length, so a
        // banded target becomes a readout rather than a constraint.
        if (segment.targetDistance?.advisory ?? false) ...[
          const SizedBox(height: PlotSpacing.s1),
          Text(
            'With three or more points to reach, the target distance is '
            'advisory: reported against the route, not used to shape it.',
            key: const ValueKey('via-advisory'),
            style: PlotTypography.small(c.textSecondary),
          ),
        ],
      ],
    );
  }
}

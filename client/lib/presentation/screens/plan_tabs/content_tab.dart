// Wireframe screen "03 Node & Narrative" — the Trip Shell's Content tab: a
// map (left) and a persistent node editor drawer (right), replacing the
// modal bottom sheet `node_editor_sheet.dart` used to be the only container
// for (that modal still exists for the Route tab's "tap map to add a node
// while routing" flow — see that file's doc comment).
//
// `selectedSegmentProvider` is the seam with the Route tab (ARCH-style: one
// provider, not a duplicate "which segment" concept per tab) — Content
// works against whichever segment Route has focused.
//
// One real simplification from the wireframe: `TapToPickMap`'s markers
// aren't individually tappable (`presentation/map/tap_to_pick_map.dart`
// only reports a raw map coordinate, not "which marker"), so selecting an
// *existing* node to edit is a chip list next to the map rather than
// tapping its marker directly — tapping the map still places a *new* node,
// which is the interaction the map itself is for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../domain/domain.dart';
import '../../../state/planner_ui_state.dart';
import '../../map/tap_to_pick_map.dart';
import '../../widgets/node_editor_sheet.dart';

class ContentTab extends ConsumerStatefulWidget {
  const ContentTab({super.key, required this.trip});
  final Trip trip;

  @override
  ConsumerState<ContentTab> createState() => _ContentTabState();
}

class _ContentTabState extends ConsumerState<ContentTab> {
  String? _selectedNodeId;
  Coord? _pendingCoord;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final selected = ref.watch(selectedSegmentProvider);
    final target = _findTarget(widget.trip, selected);

    if (target == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(PlotSpacing.s6),
          child: Text(
            'Select a segment on the Route tab to curate its nodes.',
            style: PlotTypography.body(c.textMuted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final (day, segment) = target;
    final existing = _selectedNodeId == null
        ? null
        : segment.nodes.where((n) => n.id == _selectedNodeId).firstOrNull;
    final coord = existing?.coord ?? _pendingCoord;

    return Row(
      children: [
        Expanded(
          child: Stack(
            children: [
              TapToPickMap(
                points: [for (final n in segment.nodes) n.coord],
                center: segment.start,
                onTap: (point) => setState(() {
                  _selectedNodeId = null;
                  _pendingCoord = point;
                }),
              ),
              Positioned(
                top: PlotSpacing.s3,
                left: PlotSpacing.s3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
                  decoration: BoxDecoration(
                    color: c.surfaceCard.withValues(alpha: 0.92),
                    borderRadius: PlotRadii.controlShape,
                    border: Border.all(color: c.border),
                  ),
                  child: Text('Tap the map to place a new node', style: PlotTypography.data(c.textMuted)),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 400,
          decoration: BoxDecoration(border: Border(left: BorderSide(color: c.border))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (segment.nodes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(PlotSpacing.s3),
                  child: Wrap(
                    spacing: PlotSpacing.s2,
                    runSpacing: PlotSpacing.s2,
                    children: [
                      for (final n in segment.nodes)
                        ChoiceChip(
                          label: Text(n.title ?? n.kind.wireValue),
                          selected: n.id == _selectedNodeId,
                          onSelected: (_) => setState(() {
                            _selectedNodeId = n.id;
                            _pendingCoord = null;
                          }),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: coord == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(PlotSpacing.s5),
                          child: Text('Tap the map, or pick a node above, to curate it.',
                              style: PlotTypography.body(c.textMuted), textAlign: TextAlign.center),
                        ),
                      )
                    : NodeEditorForm(
                        key: ValueKey(existing?.id ?? 'new-${coord[0]}-${coord[1]}'),
                        dayId: day.id,
                        segmentId: segment.id,
                        coord: coord,
                        existing: existing,
                        onSaved: (node) => setState(() {
                          _selectedNodeId = node.id;
                          _pendingCoord = null;
                        }),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  (Day, Segment)? _findTarget(Trip trip, (String, String)? selected) {
    if (selected == null) return null;
    for (final d in trip.days) {
      if (d.id != selected.$1) continue;
      for (final s in d.segments) {
        if (s.id == selected.$2) return (d, s);
      }
    }
    return null;
  }
}

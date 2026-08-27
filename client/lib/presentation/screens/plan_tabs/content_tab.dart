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
import '../../../state/current_trip_provider.dart';
import '../../../state/planner_ui_state.dart';
import '../../map/tap_to_pick_map.dart';
import '../../widgets/anchor_promotion_panel.dart';
import '../../widgets/node_editor_sheet.dart';
import '../../widgets/note_media_editor.dart';

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
    return Column(
      children: [
        // FR106, FR110 / O1 — trip-scoped, so it does not require a segment
        // selection the way the node editor below it does.
        AnchorPromotionPanel(trip: widget.trip),
        Expanded(child: _buildNodeEditor(context)),
      ],
    );
  }

  Widget _buildNodeEditor(BuildContext context) {
    final c = PlotColors.of(context);
    final selected = ref.watch(selectedSegmentProvider);
    final target = resolveSelectedSegment(widget.trip, selected);

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
              _PassageAndDayContent(day: day, segment: segment),
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

}

/// FR37 / E1 — the other two of the AC's three content homes (role content
/// lives on the anchor card, `anchor_promotion_panel.dart`'s `_RoleChip`):
/// a passage's (segment's) own note/media, distinct from any node or role
/// along it, and the day's own — collapsed by default so an Author who
/// never uses this doesn't pay for it in the node editor's limited vertical
/// space below.
class _PassageAndDayContent extends ConsumerWidget {
  const _PassageAndDayContent({required this.day, required this.segment});
  final Day day;
  final Segment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final hasContent = segment.note != null ||
        segment.media.isNotEmpty ||
        day.note != null ||
        day.media.isNotEmpty;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        title: Text(
          hasContent ? 'PASSAGE & DAY CONTENT' : 'PASSAGE & DAY CONTENT (empty)',
          style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700, fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
        children: [
          Text('PASSAGE', style: PlotTypography.small(c.textMuted)),
          const SizedBox(height: PlotSpacing.s1),
          NoteMediaEditor(
            key: ValueKey('passage-${segment.id}'),
            note: segment.note,
            media: segment.media,
            noteLabel: 'Passage note',
            onNoteChanged: (v) =>
                ref.read(currentTripProvider.notifier).updateSegmentNote(day.id, segment.id, v),
            onMediaChanged: (v) =>
                ref.read(currentTripProvider.notifier).updateSegmentMedia(day.id, segment.id, v),
          ),
          const SizedBox(height: PlotSpacing.s4),
          Text('DAY ${day.index}', style: PlotTypography.small(c.textMuted)),
          const SizedBox(height: PlotSpacing.s1),
          NoteMediaEditor(
            key: ValueKey('day-${day.id}'),
            note: day.note,
            media: day.media,
            noteLabel: 'Day note',
            onNoteChanged: (v) => ref.read(currentTripProvider.notifier).setDayNote(day.id, v),
            onMediaChanged: (v) =>
                ref.read(currentTripProvider.notifier).updateDayMedia(day.id, v),
          ),
        ],
      ),
    );
  }
}

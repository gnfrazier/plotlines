// FR38 / O6 — issue #392: the map-side half of "arc roles ... are
// distinguished on map and timeline". `day_timeline_strip.dart`'s
// `_SegmentChip` already shows a passage's own `arcStage` as a slate
// `PlotBadge`; this is the equivalent mark for the map, where `TapToPickMap`
// draws points (`Node.arcStage`) and the day's solved line (a passage's own
// `Segment.arcStage`).
//
// Shape carries the meaning — the brand guardrail every map marker in this
// app follows (`node_marker.dart`'s own doc comment: "shape carries the
// meaning and color only reinforces it"). Five stages get five distinct
// icons; color is a second, reinforcing signal, never the only one.
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

/// The five `ArcStage.wireValue` strings (`domain/anchor.dart`) — kept as raw
/// strings here rather than the typed enum because both callers of this file
/// (`tap_to_pick_map.dart`'s [MapMarkerPoint], `Segment.arcStage`) already
/// carry arc stage as an unvalidated wire string, matching `Node.arcStage`'s
/// existing precedent (`content/anchor.py`'s dev-complete note: "`trips`
/// treats the schema as the sole validation authority for enum-shaped
/// fields"). An unrecognised value draws no badge rather than throwing —
/// this is a display concern, not a validation boundary.
const _arcStageIcons = <String, IconData>{
  'exposition': Icons.menu_book_rounded,
  'rising': Icons.trending_up_rounded,
  'crux': Icons.change_history_rounded,
  'climax': Icons.star_rounded,
  'resolution': Icons.check_circle_rounded,
};

IconData? arcStageIcon(String stage) => _arcStageIcons[stage];

Color arcStageColor(PlotColors c, String stage) => switch (stage) {
      'exposition' => c.textSecondary,
      'rising' => c.info,
      'crux' => c.warning,
      'climax' => c.primary,
      'resolution' => c.success,
      _ => c.textSecondary,
    };

/// A small ringed-icon badge for a map point or line that carries an arc
/// stage. Deliberately a corner tag, not a replacement marker: arc is an
/// attribute of the point/passage, not what it *is* — `NodeMarker`'s own
/// shape still carries that.
class ArcStageBadge extends StatelessWidget {
  const ArcStageBadge(this.stage, {super.key, this.size = 15});

  final String stage;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = arcStageIcon(stage);
    if (icon == null) return const SizedBox.shrink();
    final c = PlotColors.of(context);
    final color = arcStageColor(c, stage);
    return Tooltip(
      // Matches `day_timeline_strip.dart`'s own badge, which labels the arc
      // stage with its raw wire string rather than a composed sentence.
      message: 'Arc: $stage',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.surfaceCard,
          border: Border.all(color: color, width: 1.4),
        ),
        child: Icon(icon, size: size * 0.62, color: color),
      ),
    );
  }
}

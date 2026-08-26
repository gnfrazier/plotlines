// Wireframe screen "01 Route Planner"'s day timeline — day tabs across the
// top, the active day's segments as a horizontal strip below with a
// transition glyph between adjacent segments (`Day.transitions`, modeled in
// the schema since SPIKE-20 but never surfaced in any UI until now) and a
// day-limit breach chip (`Day.limits`, same story — real data, no prior UI).
//
// FR11 / B2: this strip is where a day's passage *order* is set and where the
// adjacency gap warning lands. The order is left-to-right, which is the whole
// reason the reorder control is a pair of arrows on the selected passage
// rather than a drag handle — a horizontally scrolling strip gives a drag
// nowhere obvious to go, and "move this leg one earlier" is the edit an
// Author actually makes. The measurement itself is
// `domain/passage_sequence.dart` (mirroring `trips/compose.py`), never
// recomputed here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import 'transition_editor_sheet.dart';
import 'transition_strand_prompt.dart';
import 'travel_mode_icons.dart';

class DayTimelineStrip extends ConsumerWidget {
  const DayTimelineStrip({
    super.key,
    required this.trip,
    required this.activeDayId,
    required this.onSelectDay,
  });
  final Trip trip;
  final String? activeDayId;
  final ValueChanged<String> onSelectDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final activeDay = trip.days.isEmpty
        ? null
        : trip.days.firstWhere((d) => d.id == activeDayId, orElse: () => trip.days.first);

    return Container(
      height: 172,
      decoration: BoxDecoration(
        color: c.surfaceApp,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3),
              children: [
                for (final day in trip.days)
                  Padding(
                    padding: const EdgeInsets.only(right: PlotSpacing.s2),
                    child: ChoiceChip(
                      label: Text('DAY ${day.index}${day.isRest ? ' · REST' : ''}'),
                      selected: day.id == activeDay?.id,
                      onSelected: (_) => onSelectDay(day.id),
                    ),
                  ),
                IconButton(
                  tooltip: 'New route day',
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () {
                    ref.read(plannerTargetDayIdProvider.notifier).state = null;
                    context.push('/new');
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: c.surfaceCard,
                border: Border(top: BorderSide(color: c.border)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s4, vertical: PlotSpacing.s3),
              child: activeDay == null
                  ? Center(child: Text('No days yet', style: PlotTypography.small(c.textMuted)))
                  : _DaySegmentStrip(day: activeDay),
            ),
          ),
        ],
      ),
    );
  }
}

class _DaySegmentStrip extends ConsumerWidget {
  const _DaySegmentStrip({required this.day});
  final Day day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    if (day.isRest) {
      return Row(
        children: [
          Icon(Icons.hotel_outlined, size: 18, color: c.textMuted),
          const SizedBox(width: PlotSpacing.s2),
          Text('Rest day', style: PlotTypography.body(c.textSecondary)),
        ],
      );
    }
    if (day.segments.isEmpty) {
      return Center(
        child: Text('No segments yet — Add segment from Logistics.',
            style: PlotTypography.small(c.textMuted)),
      );
    }
    double dayDistance = 0;
    for (final s in day.segments) {
      dayDistance += s.metrics?.distanceM ?? 0;
    }
    final breach = _breach(day, dayDistance);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < day.segments.length; i++) ...[
            if (i > 0)
              _TransitionGlyph(dayId: day.id, transition: transitionBefore(day, i)),
            _SegmentChip(
              day: day,
              segment: day.segments[i],
              position: i,
              count: day.segments.length,
            ),
          ],
          if (breach != null) ...[
            const SizedBox(width: PlotSpacing.s4),
            _BreachChip(text: breach),
          ],
        ],
      ),
    );
  }

  String? _breach(Day day, double dayDistance) {
    final limit = day.limits['distance_m'];
    if (limit == null) return null;
    // FR38 / O6 (C3) — a day that closes at a resolution-stage anchor is
    // exempt from falling short of the band: the story ended on purpose, not
    // by accident. Mirrors `trips.compose._ends_at_resolution` server-side —
    // running long past the band is still flagged; only "under" is excused.
    if (limit.minM != null && dayDistance < limit.minM! && !_endsAtResolution(day)) {
      return '${(dayDistance / 1000).toStringAsFixed(0)} km · below ${(limit.minM! / 1000).toStringAsFixed(0)}–'
          '${limit.maxM == null ? '∞' : (limit.maxM! / 1000).toStringAsFixed(0)} km limit';
    }
    if (limit.maxM != null && dayDistance > limit.maxM!) {
      return '${(dayDistance / 1000).toStringAsFixed(0)} km · above ${limit.minM == null ? '0' : (limit.minM! / 1000).toStringAsFixed(0)}–'
          '${(limit.maxM! / 1000).toStringAsFixed(0)} km limit';
    }
    return null;
  }

  bool _endsAtResolution(Day day) {
    if (day.segments.isEmpty) return false;
    final nodes = day.segments.last.nodes;
    if (nodes.isEmpty) return false;
    final ordered = [...nodes]..sort((a, b) {
        final aUnset = a.distanceAlongM == null;
        final bUnset = b.distanceAlongM == null;
        if (aUnset != bUnset) return aUnset ? -1 : 1;
        return (a.distanceAlongM ?? 0.0).compareTo(b.distanceAlongM ?? 0.0);
      });
    return ordered.last.arcStage == 'resolution';
  }
}

class _SegmentChip extends ConsumerWidget {
  const _SegmentChip({
    required this.day,
    required this.segment,
    required this.position,
    required this.count,
  });
  final Day day;
  final Segment segment;

  /// 0-based place in the day, and how many passages the day holds — the two
  /// facts the reorder arrows need to know which of them can do anything.
  final int position;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final selected = ref.watch(selectedSegmentProvider) == (day.id, segment.id);
    final km = segment.metrics?.distanceM == null ? null : segment.metrics!.distanceM! / 1000;
    return InkWell(
      borderRadius: PlotRadii.controlShape,
      onTap: () => ref.read(selectedSegmentProvider.notifier).state = (day.id, segment.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
        decoration: BoxDecoration(
          color: selected ? c.primary.withValues(alpha: 0.1) : c.surfaceCard,
          border: Border.all(color: selected ? c.primary : c.border, width: selected ? 1.5 : 1),
          borderRadius: PlotRadii.controlShape,
        ),
        child: Row(
          children: [
            Icon(
              travelModeIcon(segment.mode),
              size: 20,
              color: selected ? c.primary : c.textSecondary,
            ),
            const SizedBox(width: PlotSpacing.s2),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(travelModeLabel(segment.mode),
                    style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
                Text(
                  km == null ? '—' : '${km.toStringAsFixed(1)} km',
                  style: PlotTypography.small(c.textMuted),
                ),
              ],
            ),
            // FR38 / O6 — this passage's own arc stage, distinguished on the
            // timeline the way `_BreachChip`/`_TransitionGlyph` already
            // distinguish their own facts about a segment: absent for the
            // common case of a segment with no arc beat.
            if (segment.arcStage != null) ...[
              const SizedBox(width: PlotSpacing.s2),
              PlotBadge(segment.arcStage!, tone: PlotBadgeTone.slate),
            ],
            // FR11 / B2 — reorder, shown only on the selected passage so the
            // strip doesn't sprout two buttons per leg. Each arrow is hidden
            // rather than disabled at the end it cannot move toward: there is
            // nothing to explain about "you cannot move the first leg
            // earlier", and a dead control invites a second click.
            if (selected && count > 1) ...[
              const SizedBox(width: PlotSpacing.s2),
              if (position > 0)
                _MoveButton(
                  icon: Icons.chevron_left,
                  tooltip: 'Move earlier in the day',
                  onPressed: () => _move(context, ref, by: -1),
                ),
              if (position < count - 1)
                _MoveButton(
                  icon: Icons.chevron_right,
                  tooltip: 'Move later in the day',
                  onPressed: () => _move(context, ref, by: 1),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// FR11/B2 with FR12/B3's content at stake: a reorder that pulls apart a
  /// junction carrying Author instructions has to say what it will drop
  /// (FR139's rule — triggered by authored content, not by object type).
  /// A move that strands nothing authored just happens.
  Future<void> _move(BuildContext context, WidgetRef ref, {required int by}) async {
    final notifier = ref.read(currentTripProvider.notifier);
    final newOrder = reorderPassages(
      day.segments,
      position,
      by > 0 ? position + by + 1 : position + by,
    );
    final stranded = strandedInstructedTransitions(day, newOrder);
    if (stranded.isNotEmpty) {
      final confirmed = await showTransitionStrandPrompt(context, stranded: stranded);
      if (confirmed != true) return;
    }
    notifier.movePassage(day.id, segment.id, by: by);
  }
}

class _MoveButton extends StatelessWidget {
  const _MoveButton({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18, color: c.textSecondary),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}

class _TransitionGlyph extends StatelessWidget {
  const _TransitionGlyph({required this.dayId, this.transition});
  final String dayId;
  final Transition? transition;

  @override
  Widget build(BuildContext context) {
    final glyph = _glyph(context);
    if (transition == null) return glyph;
    // FR12 / B3 — the junction is the thing an Author points at to place a
    // transition node, so it is the control that opens the editor. Nothing
    // else on this strip represents "between these two passages".
    return InkWell(
      borderRadius: PlotRadii.controlShape,
      onTap: () => showTransitionEditorSheet(context, dayId: dayId, transition: transition!),
      child: Tooltip(message: _tooltip(), child: glyph),
    );
  }

  /// One message, in the order an Author needs it: the hole in the day first
  /// (B2), then what they wrote about it, then the invitation to write
  /// something if they haven't.
  String _tooltip() {
    final t = transition!;
    final parts = <String>[
      if (t.gapWarning ?? false)
        'These two passages do not meet — ${_metres(t.gapM)} between the first '
            "one's end and the next one's start (warns above "
            '${(kDefaultGapWarnM / 1000).toStringAsFixed(1)} km).',
      if (t.instructions != null) t.instructions!,
    ];
    if (parts.isEmpty) return 'Add transition instructions';
    return parts.join('\n\n');
  }

  static String _metres(double? gapM) =>
      gapM == null ? 'an unmeasured distance' : '${gapM.round()} m';

  Widget _glyph(BuildContext context) {
    final c = PlotColors.of(context);
    final warn = transition?.gapWarning ?? false;
    final instructed = transition?.instructions != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // FR12 / B3 — a junction carrying Author instructions is a different
          // thing from a bare mode change, and a Character has to be able to
          // tell at a glance which junctions have something to read. A filled
          // note glyph says so without a second row of text.
          Icon(
            instructed ? Icons.sticky_note_2 : Icons.compare_arrows,
            size: 20,
            color: warn
                ? c.danger
                : instructed
                    ? c.primary
                    : c.textMuted,
          ),
          // FR11 / B2 — the gap is a *number*, so it is set in mono and stated
          // rather than implied: "GAP 1.2 KM" tells an Author whether this is a
          // walk across a car park or a hole in the day. Gold is a fill here,
          // never text (brand guardrail), so the warning is a solid badge while
          // the ordinary case stays a quiet caption.
          if (warn)
            PlotBadge(_gapLabel(transition!.gapM), tone: PlotBadgeTone.gold, solid: true)
          else
            Text(
              _label(),
              style: PlotTypography.small(c.textMuted).copyWith(fontSize: 8),
            ),
        ],
      ),
    );
  }

  static String _gapLabel(double? gapM) => gapM == null
      ? 'GAP'
      : gapM >= 1000
          ? 'GAP ${(gapM / 1000).toStringAsFixed(1)} km'
          : 'GAP ${gapM.round()} m';

  /// "Portage" is only the right word for a mode change into or out of
  /// paddling — any other mode change (e.g. ride to hike) is a generic
  /// transition, not a boat carry.
  String _label() {
    final from = transition?.fromMode;
    final to = transition?.toMode;
    if (from == 'paddling' || to == 'paddling') return 'PORTAGE';
    return 'TRANSITION';
  }
}

class _BreachChip extends StatelessWidget {
  const _BreachChip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.08),
        border: Border.all(color: c.danger.withValues(alpha: 0.35)),
        borderRadius: PlotRadii.controlShape,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: c.danger),
          const SizedBox(width: PlotSpacing.s2),
          Text(text, style: PlotTypography.small(c.danger)),
        ],
      ),
    );
  }
}

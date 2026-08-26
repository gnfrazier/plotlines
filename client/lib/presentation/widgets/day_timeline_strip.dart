// Wireframe screen "01 Route Planner"'s day timeline — day tabs across the
// top, the active day's segments as a horizontal strip below with a
// transition glyph between adjacent segments (`Day.transitions`, modeled in
// the schema since SPIKE-20 but never surfaced in any UI until now) and a
// day-limit breach chip (`Day.limits`, same story — real data, no prior UI).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/planner_ui_state.dart';

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
            if (i > 0) _TransitionGlyph(transition: _transitionBetween(day, i)),
            _SegmentChip(day: day, segment: day.segments[i]),
          ],
          if (breach != null) ...[
            const SizedBox(width: PlotSpacing.s4),
            _BreachChip(text: breach),
          ],
        ],
      ),
    );
  }

  Transition? _transitionBetween(Day day, int i) {
    final fromId = day.segments[i - 1].id;
    final toId = day.segments[i].id;
    for (final t in day.transitions) {
      if (t.fromSegmentId == fromId && t.toSegmentId == toId) return t;
    }
    return null;
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
  const _SegmentChip({required this.day, required this.segment});
  final Day day;
  final Segment segment;

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
              switch (segment.mode) {
                'hiking' => Icons.hiking,
                'paddling' => Icons.kayaking,
                'transit' => Icons.directions_transit,
                _ => Icons.directions_bike,
              },
              size: 20,
              color: selected ? c.primary : c.textSecondary,
            ),
            const SizedBox(width: PlotSpacing.s2),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(segment.mode, style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
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
          ],
        ),
      ),
    );
  }
}

class _TransitionGlyph extends StatelessWidget {
  const _TransitionGlyph({this.transition});
  final Transition? transition;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final warn = transition?.gapWarning ?? false;
    final label = _label(warn);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.compare_arrows, size: 20, color: warn ? c.warning : c.textMuted),
          Text(
            label,
            style: PlotTypography.small(warn ? c.warning : c.textMuted).copyWith(fontSize: 8),
          ),
        ],
      ),
    );
  }

  /// "Portage" is only the right word for a mode change into or out of
  /// paddling — any other mode change (e.g. ride to hike) is a generic
  /// transition, not a boat carry.
  String _label(bool warn) {
    if (warn) return 'GAP';
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

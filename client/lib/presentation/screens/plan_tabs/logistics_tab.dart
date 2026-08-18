// The Trip Shell's Logistics tab. Not a wireframe screen — the 2026-08-17
// `Plotlines Author Desktop.dc.html` file names this tab in every screen's
// tab bar but never mocks its content (checked directly against the file:
// a `data-screen-label` exists for New Route/Route Planner/Constraint
// Conflict/Node & Narrative/Cue Sheet+Export/Open Trip/Preferences/System
// States, and none for Logistics). This tab's content is this repo's own
// design, not a missed reconciliation: the day/rest-day list that used to
// sit in `route_planner_screen.dart`'s left column (now the Route tab's map
// canvas instead, per the wireframe) moved here, since multi-day logistics
// is what MVP §1.4 Epic C actually describes and there's nowhere else for
// it once Route's rail is the weights panel. Also adds day-limit (C1-C3)
// editing — `Day.limits`/`DayLimit` exist and `/days/compose` already
// enforces them server-side, but no UI ever set them before this tab.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../domain/domain.dart';
import '../../../state/current_trip_provider.dart';
import '../../../state/planner_ui_state.dart';

class LogisticsTab extends ConsumerWidget {
  const LogisticsTab({super.key, required this.trip, required this.onOpenSegment});
  final Trip trip;
  final void Function(String dayId, String segmentId) onOpenSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(PlotSpacing.s5),
            children: [
              for (final day in trip.days) _DayCard(day: day, onOpenSegment: onOpenSegment),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(PlotSpacing.s4),
          child: Row(
            children: [
              Expanded(
                child: PlotButton(
                  label: 'New route day',
                  variant: PlotButtonVariant.secondary,
                  icon: Icons.add,
                  onPressed: () {
                    ref.read(plannerTargetDayIdProvider.notifier).state = null;
                    context.push('/new');
                  },
                ),
              ),
              const SizedBox(width: PlotSpacing.s2),
              // C2 — a rest day is a day with no segments, created directly
              // here since it never needs the New Route flow. `addBlankDay`,
              // not `setDayKind` — the latter only ever looks up an
              // *existing* day and throws given a fresh id.
              IconButton(
                tooltip: 'Add rest day',
                icon: Icon(Icons.hotel_outlined, color: PlotColors.of(context).textSecondary),
                onPressed: () => ref.read(currentTripProvider.notifier).addBlankDay(kind: 'rest'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DayCard extends ConsumerWidget {
  const _DayCard({required this.day, required this.onOpenSegment});
  final Day day;
  final void Function(String dayId, String segmentId) onOpenSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
      child: PlotCard(
        padding: const EdgeInsets.all(PlotSpacing.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Day ${day.index}', style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: PlotSpacing.s2),
                if (day.roles.contains('start')) const PlotBadge('Start', tone: PlotBadgeTone.spruce),
                if (day.roles.contains('end')) const PlotBadge('End', tone: PlotBadgeTone.spruce),
                if (day.isRest) const PlotBadge('Rest', tone: PlotBadgeTone.slate),
                const Spacer(),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, size: 18, color: c.textMuted),
                  onSelected: (action) {
                    final notifier = ref.read(currentTripProvider.notifier);
                    switch (action) {
                      case 'start':
                        notifier.toggleDayRole(day.id, 'start');
                      case 'end':
                        notifier.toggleDayRole(day.id, 'end');
                      case 'rest':
                        notifier.setDayKind(day.id, day.isRest ? 'route' : 'rest');
                      case 'remove':
                        notifier.removeDay(day.id);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'start', child: Text('Toggle Start')),
                    PopupMenuItem(value: 'end', child: Text('Toggle End')),
                    PopupMenuItem(value: 'rest', child: Text('Toggle Rest day')),
                    PopupMenuItem(value: 'remove', child: Text('Remove day')),
                  ],
                ),
              ],
            ),
            for (final segment in day.segments)
              _SegmentTile(day: day, segment: segment, onOpen: () => onOpenSegment(day.id, segment.id)),
            if (!day.isRest) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: PlotButton(
                  label: 'Add segment',
                  variant: PlotButtonVariant.ghost,
                  icon: Icons.add,
                  onPressed: () {
                    ref.read(plannerTargetDayIdProvider.notifier).state = day.id;
                    context.push('/new');
                  },
                ),
              ),
              const SizedBox(height: PlotSpacing.s3),
              _DayLimitEditor(day: day),
            ],
          ],
        ),
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({required this.day, required this.segment, required this.onOpen});
  final Day day;
  final Segment segment;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final km = segment.metrics?.distanceM == null ? null : segment.metrics!.distanceM! / 1000;
    final stale = segment.solve?.stale ?? false;
    return PlotListTile(
      onTap: onOpen,
      leading: Icon(
        switch (segment.mode) {
          'hiking' => Icons.hiking,
          'paddling' => Icons.kayaking,
          'transit' => Icons.directions_transit,
          _ => Icons.directions_bike,
        },
        color: c.textSecondary,
      ),
      title: '${segment.mode} · ${segment.shape.replaceAll('_', ' ')}',
      subtitle: segment.nodes.isEmpty ? null : '${segment.nodes.length} node(s)',
      trailingMono: km == null ? '—' : '${km.toStringAsFixed(1)} km',
      trailing: stale ? Icon(Icons.sync_problem, size: 16, color: c.warning) : null,
    );
  }
}

/// C1-C3 — per-day distance limits overriding the trip default
/// (`Trip.dayLimits`), feeding `/days/compose`'s existing breach detection
/// (already surfaced on the Route tab's day timeline strip as a chip).
class _DayLimitEditor extends ConsumerStatefulWidget {
  const _DayLimitEditor({required this.day});
  final Day day;

  @override
  ConsumerState<_DayLimitEditor> createState() => _DayLimitEditorState();
}

class _DayLimitEditorState extends ConsumerState<_DayLimitEditor> {
  late final _min = TextEditingController(
    text: widget.day.limits['distance_m']?.minM == null
        ? ''
        : (widget.day.limits['distance_m']!.minM! / 1000).toStringAsFixed(0),
  );
  late final _max = TextEditingController(
    text: widget.day.limits['distance_m']?.maxM == null
        ? ''
        : (widget.day.limits['distance_m']!.maxM! / 1000).toStringAsFixed(0),
  );

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _emit() {
    final minKm = double.tryParse(_min.text);
    final maxKm = double.tryParse(_max.text);
    final limits = {...widget.day.limits};
    if (minKm == null && maxKm == null) {
      limits.remove('distance_m');
    } else {
      limits['distance_m'] = DayLimit(
        minM: minKm == null ? null : minKm * 1000,
        maxM: maxKm == null ? null : maxKm * 1000,
      );
    }
    ref.read(currentTripProvider.notifier).updateDayLimits(widget.day.id, limits);
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      sunk: true,
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Row(
        children: [
          Text('DISTANCE LIMIT (km)', style: PlotTypography.data(c.textMuted)),
          const Spacer(),
          SizedBox(
            width: 64,
            child: TextField(
              controller: _min,
              decoration: const InputDecoration(hintText: 'min', isDense: true),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _emit(),
            ),
          ),
          const SizedBox(width: PlotSpacing.s2),
          SizedBox(
            width: 64,
            child: TextField(
              controller: _max,
              decoration: const InputDecoration(hintText: 'max', isDense: true),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _emit(),
            ),
          ),
        ],
      ),
    );
  }
}

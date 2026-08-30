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
import 'package:intl/intl.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../../domain/domain.dart';
import '../../../state/current_trip_provider.dart';
import '../../../state/planner_ui_state.dart';
import '../../map/tap_to_pick_map.dart';
import '../../widgets/day_removal_prompt.dart';

class LogisticsTab extends ConsumerWidget {
  const LogisticsTab({super.key, required this.trip, required this.onOpenSegment});
  final Trip trip;
  final void Function(String dayId, String segmentId) onOpenSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final staleCount = tripStaleCount(trip);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(PlotSpacing.s5),
            children: [
              // FR140/Q3's AC: "while planning this is passive only — a
              // marker on the object and a count in the dashboard... no
              // modal, no banner, no interruption." This is that count —
              // deliberately plain text, not `error_states.dart`'s banner
              // idiom (FR140a: stale work is pending work, not a failure).
              if (staleCount > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
                  child: Text(
                    '$staleCount stale ${staleCount == 1 ? 'route' : 'routes'} — needs re-solving before export',
                    style: PlotTypography.small(PlotColors.of(context).textMuted),
                  ),
                ),
              _TripDurationCard(trip: trip),
              const SizedBox(height: PlotSpacing.s3),
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

/// FR17 / C1 — "Authors define adventure duration ... via start/end dates or
/// a day count." Both live here, on the tab that owns the day list itself,
/// rather than only at trip creation (New Route's date picker still writes
/// the same [Trip.duration] field): a day count that grows or shrinks the
/// trip funnels through [CurrentTripNotifier.setDayCount], which shares
/// Q1's content-preserving shrink behaviour, so a count typed here never
/// discards authored work silently.
class _TripDurationCard extends ConsumerStatefulWidget {
  const _TripDurationCard({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_TripDurationCard> createState() => _TripDurationCardState();
}

class _TripDurationCardState extends ConsumerState<_TripDurationCard> {
  late final _dayCountController =
      TextEditingController(text: widget.trip.days.length.toString());

  @override
  void didUpdateWidget(covariant _TripDurationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.trip.days.length.toString();
    if (_dayCountController.text != count) _dayCountController.text = count;
  }

  @override
  void dispose() {
    _dayCountController.dispose();
    super.dispose();
  }

  String _dateRangeLabel() {
    final duration = widget.trip.duration;
    final start = duration?.startDate == null ? null : DateTime.tryParse(duration!.startDate!);
    final end = duration?.endDate == null ? null : DateTime.tryParse(duration!.endDate!);
    if (start == null) return 'No dates set';
    if (end == null || DateUtils.isSameDay(start, end)) return DateFormat('MMM d, y').format(start);
    return '${DateFormat('MMM d').format(start)} – ${DateFormat('MMM d, y').format(end)}';
  }

  Future<void> _pickDates() async {
    final duration = widget.trip.duration;
    final now = DateTime.now();
    final initialStart =
        (duration?.startDate == null ? null : DateTime.tryParse(duration!.startDate!)) ?? now;
    final initialEnd = (duration?.endDate == null ? null : DateTime.tryParse(duration!.endDate!)) ??
        initialStart.add(const Duration(days: 3));
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      initialDateRange: DateTimeRange(
        start: initialStart,
        end: initialEnd.isBefore(initialStart) ? initialStart : initialEnd,
      ),
    );
    if (range == null) return;
    ref.read(currentTripProvider.notifier).setDuration(TripDuration(
          startDate: DateFormat('yyyy-MM-dd').format(range.start),
          endDate: DateFormat('yyyy-MM-dd').format(range.end),
        ));
  }

  Future<void> _submitDayCount() async {
    final target = int.tryParse(_dayCountController.text);
    if (target == null || target == widget.trip.days.length) return;
    final notifier = ref.read(currentTripProvider.notifier);
    final beyond = notifier.setDayCount(target);
    if (beyond.isEmpty) return;
    if (!mounted) return;
    final labels = beyond.length == 1
        ? 'Day ${beyond.single.index}'
        : 'Days ${beyond.first.index}–${beyond.last.index}';
    final choice = await showDayRemovalPrompt(
      context,
      dayLabels: labels,
      summary: summarizeDaysContent(beyond),
    );
    switch (choice) {
      case DayRemovalChoice.mergeIntoAdjacent:
        notifier.mergeDaysIntoAdjacent({for (final d in beyond) d.id});
      case DayRemovalChoice.removeExplicitly:
        notifier.removeDaysExplicitly({for (final d in beyond) d.id});
      case DayRemovalChoice.keep:
      case null:
        // FR139: declining leaves the trip as it stood before the count
        // change — the days [setDayCount] would have removed are still
        // empty-trailing-only-excluded, i.e. still present.
        _dayCountController.text = widget.trip.days.length.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Row(
        children: [
          Text('TRIP LENGTH', style: PlotTypography.data(c.textMuted)),
          const Spacer(),
          SizedBox(
            width: 48,
            child: TextField(
              controller: _dayCountController,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(isDense: true),
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _submitDayCount(),
            ),
          ),
          const SizedBox(width: PlotSpacing.s2),
          Text(widget.trip.days.length == 1 ? 'day' : 'days',
              style: PlotTypography.body(c.textSecondary)),
          const SizedBox(width: PlotSpacing.s4),
          Expanded(
            child: Text(_dateRangeLabel(),
                textAlign: TextAlign.right, style: PlotTypography.body(c.textSecondary)),
          ),
          const SizedBox(width: PlotSpacing.s2),
          PlotButton(
            label: 'Edit dates',
            variant: PlotButtonVariant.ghost,
            onPressed: _pickDates,
          ),
        ],
      ),
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
                  onSelected: (action) async {
                    final notifier = ref.read(currentTripProvider.notifier);
                    switch (action) {
                      case 'start':
                        notifier.toggleDayRole(day.id, 'start');
                      case 'end':
                        notifier.toggleDayRole(day.id, 'end');
                      case 'rest':
                        notifier.setDayKind(day.id, day.isRest ? 'route' : 'rest');
                      case 'insert_before':
                        notifier.insertDayAt(day.index);
                      case 'insert_after':
                        notifier.insertDayAt(day.index + 1);
                      case 'remove':
                        // FR139/Q1 — empty days are removed without a
                        // prompt; a day holding authored content states the
                        // scope and lets the Author choose rather than
                        // discarding it silently.
                        final summary = summarizeDayContent(day);
                        if (summary.isEmpty) {
                          notifier.removeDay(day.id);
                          return;
                        }
                        final choice = await showDayRemovalPrompt(
                          context,
                          dayLabels: 'Day ${day.index}',
                          summary: summary,
                        );
                        switch (choice) {
                          case DayRemovalChoice.mergeIntoAdjacent:
                            notifier.mergeDaysIntoAdjacent({day.id});
                          case DayRemovalChoice.removeExplicitly:
                            notifier.removeDaysExplicitly({day.id});
                          case DayRemovalChoice.keep:
                          case null:
                            break;
                        }
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'start', child: Text('Toggle Start')),
                    PopupMenuItem(value: 'end', child: Text('Toggle End')),
                    PopupMenuItem(value: 'rest', child: Text('Toggle Rest day')),
                    PopupMenuItem(value: 'insert_before', child: Text('Insert day before')),
                    PopupMenuItem(value: 'insert_after', child: Text('Insert day after')),
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
            if (day.isRest) _RestDayDetails(day: day),
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
      subtitle: _segmentSubtitle(segment),
      trailingMono: km == null ? '—' : '${km.toStringAsFixed(1)} km',
      trailing: stale ? Icon(Icons.sync_problem, size: 16, color: c.warning) : null,
    );
  }
}

/// FR20 / C4 [AMENDED v2.0] — the segment tile names its nodes and, separately,
/// its alternates *by intent* so an Author reading the day sees the accommodation
/// / branch distinction at a glance. An accommodation alternate adjusts effort; a
/// branch alternate is a story choice carrying its own content. Read-only here —
/// the alternate editor is a later surface.
String? _segmentSubtitle(Segment segment) {
  final parts = <String>[
    if (segment.nodes.isNotEmpty) '${segment.nodes.length} node(s)',
  ];
  final accommodation = segment.alternates.where((a) => !a.isBranch).length;
  final branch = segment.alternates.where((a) => a.isBranch).length;
  if (accommodation > 0) parts.add('$accommodation accommodation alt(s)');
  if (branch > 0) parts.add('$branch branch alt(s)');
  return parts.isEmpty ? null : parts.join(' · ');
}

/// FR19 / C3 — per-mode distance limits overriding the trip default
/// (`Trip.dayLimits`), feeding `computeDayLimitBreaches`' breach detection
/// (surfaced on the Route tab's day timeline strip and the metrics
/// dashboard, both as one-chip/one-row-per-mode). `Day.limits`' keys are
/// travel modes — a day mixing cycling and hiking needs its own band per
/// mode, not one blended distance for the whole day — so this renders one
/// row per limited mode plus an affordance to add a limit for another mode.
class _DayLimitEditor extends ConsumerWidget {
  const _DayLimitEditor({required this.day});
  final Day day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final limitedModes = day.limits.keys.toList()..sort();
    final dayModes = {for (final s in day.segments) s.mode};
    final addable = [
      for (final mode in kTraversalModes)
        if (!day.limits.containsKey(mode)) mode,
    ]..sort((a, b) {
        // Modes actually present on this day surface first — the likely case.
        final aPresent = dayModes.contains(a), bPresent = dayModes.contains(b);
        if (aPresent != bPresent) return aPresent ? -1 : 1;
        return a.compareTo(b);
      });

    return PlotCard(
      sunk: true,
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('DAY LIMITS (km)', style: PlotTypography.data(c.textMuted)),
              const Spacer(),
              if (addable.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Add a mode limit',
                  icon: Icon(Icons.add_circle_outline, size: 18, color: c.textMuted),
                  onSelected: (mode) => ref.read(currentTripProvider.notifier).updateDayLimits(
                        day.id,
                        {...day.limits, mode: DayLimit()},
                      ),
                  itemBuilder: (context) => [
                    for (final mode in addable)
                      PopupMenuItem(value: mode, child: Text(travelModeLabel(mode))),
                  ],
                ),
            ],
          ),
          for (final mode in limitedModes)
            Padding(
              padding: const EdgeInsets.only(top: PlotSpacing.s2),
              child: _DayLimitRow(day: day, mode: mode),
            ),
        ],
      ),
    );
  }
}

class _DayLimitRow extends ConsumerStatefulWidget {
  const _DayLimitRow({required this.day, required this.mode});
  final Day day;
  final String mode;

  @override
  ConsumerState<_DayLimitRow> createState() => _DayLimitRowState();
}

class _DayLimitRowState extends ConsumerState<_DayLimitRow> {
  late final _min = TextEditingController(text: _kmText(widget.day.limits[widget.mode]?.minM));
  late final _max = TextEditingController(text: _kmText(widget.day.limits[widget.mode]?.maxM));

  String _kmText(double? metres) => metres == null ? '' : (metres / 1000).toStringAsFixed(0);

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _emit() {
    final minKm = double.tryParse(_min.text);
    final maxKm = double.tryParse(_max.text);
    ref.read(currentTripProvider.notifier).updateDayLimits(widget.day.id, {
      ...widget.day.limits,
      widget.mode: DayLimit(
        minM: minKm == null ? null : minKm * 1000,
        maxM: maxKm == null ? null : maxKm * 1000,
      ),
    });
  }

  void _remove() {
    final limits = {...widget.day.limits}..remove(widget.mode);
    ref.read(currentTripProvider.notifier).updateDayLimits(widget.day.id, limits);
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(travelModeLabel(widget.mode), style: PlotTypography.body(c.textSecondary)),
        ),
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
        IconButton(
          tooltip: 'Remove ${travelModeLabel(widget.mode)} limit',
          icon: Icon(Icons.close, size: 16, color: c.textMuted),
          onPressed: _remove,
        ),
      ],
    );
  }
}

/// FR18 / C2 — a rest day "holds location, anchors, itinerary detail, and
/// scheduled events without an active route." [Day.segments] stays empty
/// (enforced by [Day.fromJson]/`setDayKind`); this is everywhere the rest of
/// that sentence lives: the day's own point (distinct from a route's
/// geometry), its free-text itinerary detail, and the anchors/scheduled
/// events already promotable onto [Day.nodes] from the Layers tab (N3),
/// surfaced here since Logistics is this epic's own tab and a rest day
/// otherwise shows nothing at all.
class _RestDayDetails extends ConsumerStatefulWidget {
  const _RestDayDetails({required this.day});
  final Day day;

  @override
  ConsumerState<_RestDayDetails> createState() => _RestDayDetailsState();
}

class _RestDayDetailsState extends ConsumerState<_RestDayDetails> {
  late final _title = TextEditingController(text: widget.day.title ?? '');
  late final _note = TextEditingController(text: widget.day.note ?? '');

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _editLocation() async {
    final picked = await showDialog<Coord>(
      context: context,
      builder: (context) => _LocationPickerDialog(initial: widget.day.location),
    );
    if (picked == null || !mounted) return;
    ref.read(currentTripProvider.notifier).setDayLocation(widget.day.id, picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final location = widget.day.location;
    final scheduled = widget.day.nodes.where((n) => n.scheduled != null).length;
    final anchors = widget.day.nodes.length - scheduled;
    return PlotCard(
      sunk: true,
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.place_outlined, size: 16, color: c.textMuted),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: Text(
                  location == null
                      ? 'No location set'
                      : '${location[1].toStringAsFixed(5)}, ${location[0].toStringAsFixed(5)}',
                  style: PlotTypography.body(c.textSecondary),
                ),
              ),
              PlotButton(
                label: location == null ? 'Set location' : 'Change',
                variant: PlotButtonVariant.ghost,
                onPressed: _editLocation,
              ),
              if (location != null)
                IconButton(
                  tooltip: 'Clear location',
                  icon: Icon(Icons.close, size: 16, color: c.textMuted),
                  onPressed: () =>
                      ref.read(currentTripProvider.notifier).setDayLocation(widget.day.id, null),
                ),
            ],
          ),
          const SizedBox(height: PlotSpacing.s2),
          TextField(
            controller: _title,
            decoration: const InputDecoration(hintText: 'What this day is about', isDense: true),
            onChanged: (v) => ref.read(currentTripProvider.notifier).setDayTitle(widget.day.id, v),
          ),
          const SizedBox(height: PlotSpacing.s2),
          TextField(
            controller: _note,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Itinerary detail', isDense: true),
            onChanged: (v) => ref.read(currentTripProvider.notifier).setDayNote(widget.day.id, v),
          ),
          if (widget.day.nodes.isNotEmpty) ...[
            const SizedBox(height: PlotSpacing.s2),
            Wrap(
              spacing: PlotSpacing.s2,
              runSpacing: PlotSpacing.s2,
              children: [
                if (anchors > 0) PlotBadge('$anchors ${anchors == 1 ? 'anchor' : 'anchors'}'),
                if (scheduled > 0)
                  PlotBadge('$scheduled scheduled ${scheduled == 1 ? 'event' : 'events'}'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The map picker behind [_RestDayDetails]'s "Set location"/"Change" action
/// — a single point, not a route: FR18's "rest days hold location ...
/// without an active route" means there is nothing here to solve.
class _LocationPickerDialog extends StatefulWidget {
  const _LocationPickerDialog({this.initial});
  final Coord? initial;

  @override
  State<_LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<_LocationPickerDialog> {
  Coord? _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set rest day location'),
      content: SizedBox(
        width: 480,
        height: 360,
        child: TapToPickMap(
          points: _picked == null ? const [] : [_picked!],
          center: _picked,
          onTap: (point) => setState(() => _picked = point),
        ),
      ),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
        PlotButton(
          label: 'Save',
          onPressed: _picked == null ? null : () => Navigator.pop(context, _picked),
        ),
      ],
    );
  }
}

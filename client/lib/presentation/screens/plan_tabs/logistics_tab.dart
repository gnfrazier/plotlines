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
import 'package:uuid/uuid.dart';

import '../../../domain/candidate.dart' show Candidate;
import '../../../domain/domain.dart';
import '../../../state/current_trip_provider.dart';
import '../../../state/planner_ui_state.dart';
import '../../../state/settings_provider.dart';
import '../../../state/trip_candidates_provider.dart';
import '../../map/candidate_map.dart';
import '../../map/tap_to_pick_map.dart';
import '../../widgets/alternate_editor_dialog.dart';
import '../../widgets/day_removal_prompt.dart';
import '../../widgets/gear_section.dart';
import '../../widgets/plot_date_range_picker.dart';
import '../../widgets/plot_toggle_chip.dart';

const _uuid = Uuid();

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
                    // #344 — an alternate whose fork has moved is stale in its
                    // own right, so the count is no longer routes alone. The
                    // list itself names each item by what it is; this is only
                    // the count, and it must not claim a kind it does not know.
                    '$staleCount stale ${staleCount == 1 ? 'item needs' : 'items need'} re-solving before export',
                    style: PlotTypography.small(PlotColors.of(context).textMuted),
                  ),
                ),
              _TripDurationCard(trip: trip),
              const SizedBox(height: PlotSpacing.s3),
              _OfflineBufferCard(trip: trip),
              const SizedBox(height: PlotSpacing.s3),
              for (final day in trip.days) _DayCard(day: day, onOpenSegment: onOpenSegment),
              const SizedBox(height: PlotSpacing.s4),
              const Divider(height: 1),
              const SizedBox(height: PlotSpacing.s4),
              // FR24 / C8 — gear checklist by mode and station activity, with
              // Shared Group Gear assigned to the roster. Reads the roster
              // layer, so it lives here rather than on the payload-only tab.
              GearSection(trip: trip),
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
    // Issue #230 C2 — one date picker for the app, and it is the desktop one.
    final range = await showPlotDateRangePicker(
      context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      initialRange: DateTimeRange(
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

/// Story C14 (issue #51), FR35 — "Authors set the offline data buffer
/// distance (corridor around the finished route) saved as a download
/// parameter for the adventure package." Trip-scoped, not per-day, since the
/// buffer sizes one package for the whole finished route.
///
/// **Not the trip bbox and not the home region** (ARCH D41) — this value
/// never bounds candidates, tiles, or elevation during authoring; it is
/// stored on `Trip.offlineBufferM` purely as a download parameter the
/// (not-yet-built) offline-package step reads later. Reuses the same
/// mi/km input convention `_DayLimitRow` already established:
/// `DisplayFormat.distanceInputValue`/`parseDistanceToMetres` so the field
/// reads and writes in the Author's active unit while the stored value stays
/// SI metres (ARCH D49).
class _OfflineBufferCard extends ConsumerStatefulWidget {
  const _OfflineBufferCard({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_OfflineBufferCard> createState() => _OfflineBufferCardState();
}

class _OfflineBufferCardState extends ConsumerState<_OfflineBufferCard> {
  late final _buffer = TextEditingController(text: _asInput(widget.trip.offlineBufferM));

  String _asInput(double? metres) {
    if (metres == null) return '';
    final df = ref.read(displayFormatProvider);
    return df.distanceInputValue(metres, fractionDigits: df.useMiles ? 1 : 0);
  }

  @override
  void dispose() {
    _buffer.dispose();
    super.dispose();
  }

  void _emit() {
    final df = ref.read(displayFormatProvider);
    final text = _buffer.text.trim();
    ref.read(currentTripProvider.notifier).setOfflineBufferM(
          text.isEmpty ? null : df.parseDistanceToMetres(text),
        );
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final df = ref.watch(displayFormatProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
      child: PlotCard(
        padding: const EdgeInsets.all(PlotSpacing.s3),
        child: Row(
          children: [
            Icon(Icons.download_outlined, size: 16, color: c.textMuted),
            const SizedBox(width: PlotSpacing.s2),
            Expanded(
              child: Text('Offline buffer around the finished route',
                  style: PlotTypography.body(c.textSecondary)),
            ),
            SizedBox(
              width: 72,
              child: TextField(
                controller: _buffer,
                textAlign: TextAlign.right,
                decoration: const InputDecoration(hintText: 'none', isDense: true),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onSubmitted: (_) => _emit(),
                onChanged: (_) => _emit(),
              ),
            ),
            const SizedBox(width: PlotSpacing.s2),
            Text(df.distanceUnitLabel, style: PlotTypography.body(c.textMuted)),
          ],
        ),
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
            for (final segment in day.segments) ...[
              _SegmentTile(
                day: day,
                segment: segment,
                onOpen: () => onOpenSegment(day.id, segment.id),
                displayFormat: ref.watch(displayFormatProvider),
              ),
              if (!day.isRest)
                _AlternatesSection(
                  dayId: day.id,
                  segment: segment,
                  onOpenSegment: onOpenSegment,
                ),
            ],
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
            const SizedBox(height: PlotSpacing.s3),
            _LodgingSection(day: day),
          ],
        ),
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    required this.day,
    required this.segment,
    required this.onOpen,
    required this.displayFormat,
  });
  final Day day;
  final Segment segment;
  final VoidCallback onOpen;
  final DisplayFormat displayFormat;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final distanceM = segment.metrics?.distanceM;
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
      trailingMono:
          distanceM == null ? '—' : displayFormat.formatDistance(distanceM),
      trailing: stale ? Icon(Icons.sync_problem, size: 16, color: c.warning) : null,
    );
  }
}

/// The segment tile names its nodes; its alternates get their own section
/// below ([_AlternatesSection]), grouped by the accommodation / branch intent
/// (FR20 [AMENDED v2.0] / C4).
String? _segmentSubtitle(Segment segment) {
  if (segment.nodes.isEmpty) return null;
  return '${segment.nodes.length} node(s)';
}

/// FR20 [AMENDED v2.0] / C4, Flow 11 — where a passage's alternates are
/// listed. An alternate is a second path on a passage, and it is one of two
/// things: an *accommodation* alternate is the same day at a different effort
/// (the H6 bypass/extension a Character may take on their own copy); a *branch*
/// is a story choice carrying its own [Alternate.note], [Alternate.anchorIds],
/// [Alternate.narration], and [Alternate.reveal]. This surface never blurs the
/// two — the branch fields are absent on an accommodation card, not disabled.
///
/// **Creating one is not here** (issue #324). An alternate begins as a gesture
/// on the Route tab's map: the Author marks where it leaves the day's route and
/// where it rejoins, on a line they can see. This list inspects what that
/// produced — a path with a fork, a rejoin and a measured difference — and its
/// empty state points at the gesture rather than offering a form for a path
/// that does not exist.
class _AlternatesSection extends ConsumerWidget {
  const _AlternatesSection({
    required this.dayId,
    required this.segment,
    required this.onOpenSegment,
  });
  final String dayId;
  final Segment segment;

  /// #344 — how a row hands `Move on the map` to the Route tab: the gesture
  /// happens on the map, and the map is not on this tab.
  final void Function(String dayId, String segmentId) onOpenSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final accommodation = segment.alternates.where((a) => !a.isBranch).toList();
    final branch = segment.alternates.where((a) => a.isBranch).toList();

    // Nothing yet — one line and the action that makes one, no card.
    if (segment.alternates.isEmpty) {
      final copy = emptyStateRegistry[EmptyStateContext.passageNoAlternates]!;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
        child: Text('${copy.message} ${copy.nextAction}',
            style: PlotTypography.small(c.textMuted)),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: PlotSpacing.s2, bottom: PlotSpacing.s2),
      child: PlotCard(
        sunk: true,
        padding: const EdgeInsets.all(PlotSpacing.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ALTERNATES', style: PlotTypography.data(c.textMuted)),
            if (accommodation.isNotEmpty) ...[
              const SizedBox(height: PlotSpacing.s2),
              _IntentGroupHeading(
                label: 'ACCOMMODATION',
                caption: 'Same day, different effort',
              ),
              for (final a in accommodation)
                _AlternateRow(
                  dayId: dayId,
                  segment: segment,
                  alternate: a,
                  onOpenSegment: onOpenSegment,
                ),
            ],
            if (branch.isNotEmpty) ...[
              const SizedBox(height: PlotSpacing.s2),
              _IntentGroupHeading(
                label: 'BRANCH',
                caption: 'Changes what the day contains',
              ),
              for (final a in branch)
                _AlternateRow(
                  dayId: dayId,
                  segment: segment,
                  alternate: a,
                  onOpenSegment: onOpenSegment,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IntentGroupHeading extends StatelessWidget {
  const _IntentGroupHeading({required this.label, required this.caption});
  final String label;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: PlotSpacing.s2, bottom: PlotSpacing.s1),
      child: Row(
        children: [
          PlotBadge(label,
              tone: label == 'BRANCH' ? PlotBadgeTone.gold : PlotBadgeTone.slate),
          const SizedBox(width: PlotSpacing.s2),
          Text(caption, style: PlotTypography.small(c.textMuted)),
        ],
      ),
    );
  }
}

class _AlternateRow extends ConsumerWidget {
  const _AlternateRow({
    required this.dayId,
    required this.segment,
    required this.alternate,
    required this.onOpenSegment,
  });
  final String dayId;
  final Segment segment;
  final Alternate alternate;
  final void Function(String dayId, String segmentId) onOpenSegment;

  /// #344 — the card's `Move on the map`, from this side of the app. The card
  /// closes with the request; this selects the passage, names the alternate on
  /// [alternateToMoveProvider], and switches to the Route tab, where the
  /// gesture actually runs.
  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final move = await showAlternateCard(
      context,
      dayId: dayId,
      segmentId: segment.id,
      alternateId: alternate.id,
    );
    if (!move) return;
    ref.read(alternateToMoveProvider.notifier).state = alternate.id;
    onOpenSegment(dayId, segment.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final df = ref.watch(displayFormatProvider);
    final delta = alternate.distanceDeltaM;
    // #324 — the row says where the path goes and what it costs, in place of
    // the `not drawn` it used to have room for.
    final meta = <String>[
      alternate.kind.toUpperCase(),
      if (alternate.hasForkAndRejoin)
        'leaves ${df.formatDistance(alternate.divergesAtM!)}',
      if (alternate.hasForkAndRejoin)
        'rejoins ${df.formatDistance(alternate.rejoinsAtM!)}',
      if (delta != null)
        '${delta < 0 ? '−' : '+'}${df.formatDistance(delta.abs())}',
      if (alternate.isBranch && alternate.anchorIds.isNotEmpty)
        '${alternate.anchorIds.length} ${alternate.anchorIds.length == 1 ? 'anchor' : 'anchors'}',
      if (alternate.isBranch && alternate.narration != null) 'narration',
      if (alternate.isBranch && alternate.reveal != null)
        alternate.reveal == 'on_arrival' ? 'on arrival' : 'always visible',
      // #344 — Flow 11 §06: the distances are the ones this path was solved
      // with, and they say so wherever they appear. This is one of the places
      // they appear.
      if (alternate.isStale) 'stale',
    ];
    return PlotListTile(
      onTap: () => _open(context, ref),
      title: alternate.label ?? 'Untitled alternate',
      subtitle: meta.join(' · '),
      // FR140/Q3's "a small marker on the affected object" — the same mark the
      // passage tile above carries, so a stale branch and a stale route read
      // alike while planning.
      leading: alternate.isStale
          ? Icon(Icons.sync_problem, size: 16, color: c.warning)
          : null,
      trailing: IconButton(
        tooltip: 'Remove alternate',
        icon: Icon(Icons.delete_outline, size: 16, color: c.textMuted),
        onPressed: () => ref
            .read(currentTripProvider.notifier)
            .removeAlternateFromSegment(dayId, segment.id, alternate.id),
      ),
    );
  }
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
    final df = ref.watch(displayFormatProvider);
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
              Text('DAY LIMITS (${df.distanceUnitLabel})',
                  style: PlotTypography.data(c.textMuted)),
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
  late final _min = TextEditingController(
      text: _limitAsInput(widget.day.limits[widget.mode]?.minM));
  late final _max = TextEditingController(
      text: _limitAsInput(widget.day.limits[widget.mode]?.maxM));

  /// A stored day-limit as a bare number in the Author's active route unit
  /// (issue #312) — whole km, or miles to one decimal so the value survives
  /// the round-trip [_emit] makes on edit.
  String _limitAsInput(double? metres) {
    if (metres == null) return '';
    final df = ref.read(displayFormatProvider);
    return df.distanceInputValue(metres, fractionDigits: df.useMiles ? 1 : 0);
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _emit() {
    final df = ref.read(displayFormatProvider);
    ref.read(currentTripProvider.notifier).updateDayLimits(widget.day.id, {
      ...widget.day.limits,
      widget.mode: DayLimit(
        minM: df.parseDistanceToMetres(_min.text),
        maxM: df.parseDistanceToMetres(_max.text),
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
          points: _picked == null
              ? const []
              : [(coord: _picked!, role: NodeMarkerType.waypoint)],
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

/// Story C7 (issue #43, FR23) — "Authors filter and place lodging/campground
/// options on the planning map by type." One per day, route or rest alike:
/// a route day still ends somewhere the Character sleeps, so this is not
/// rest-day-only the way [_RestDayDetails]'s bare location is.
///
/// Reads the trip-wide [tripCandidatesProvider] (the same warmed candidate
/// set the Layers tab's `_FindCandidatesButton` fills) rather than running
/// its own extraction — one candidate set per trip, per ARCH §4.1, not a
/// second extraction path for one placement flow. [_typeFilter] narrows
/// which of those candidates are lodging-relevant *and* match the selected
/// types; the map dialog only ever sees that filtered list, so "overlays
/// update with filters" (the AC) is true by construction rather than a
/// second filter re-implemented inside the dialog.
class _LodgingSection extends ConsumerStatefulWidget {
  const _LodgingSection({required this.day});
  final Day day;

  @override
  ConsumerState<_LodgingSection> createState() => _LodgingSectionState();
}

class _LodgingSectionState extends ConsumerState<_LodgingSection> {
  Set<LodgingType> _typeFilter = LodgingType.values.toSet();

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final candidatesState = ref.watch(tripCandidatesProvider);
    final lodgingCandidates = candidatesState.candidates
        .where((cand) => _typeFilter.contains(lodgingTypeOfCandidate(cand)))
        .toList();
    final placed = widget.day.nodes.where(isLodgingNode).toList();
    final everFetched = candidatesState.fetchedFor != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('LODGING', style: PlotTypography.eyebrow(c.textMuted)),
        const SizedBox(height: PlotSpacing.s2),
        Wrap(
          spacing: PlotSpacing.s2,
          runSpacing: PlotSpacing.s2,
          children: [
            for (final type in LodgingType.values)
              PlotToggleChip(
                label: type.label,
                selected: _typeFilter.contains(type),
                onTap: () => setState(() {
                  _typeFilter = _typeFilter.contains(type)
                      ? (_typeFilter.toSet()..remove(type))
                      : (_typeFilter.toSet()..add(type));
                }),
              ),
          ],
        ),
        if (placed.isNotEmpty) ...[
          const SizedBox(height: PlotSpacing.s2),
          Wrap(
            spacing: PlotSpacing.s2,
            runSpacing: PlotSpacing.s2,
            children: [
              for (final node in placed)
                Chip(
                  label: Text(node.title ?? (node.poiType ?? 'Lodging')),
                  onDeleted: () =>
                      ref.read(currentTripProvider.notifier).removeNodesById({node.id}),
                ),
            ],
          ),
        ],
        const SizedBox(height: PlotSpacing.s2),
        Align(
          alignment: Alignment.centerLeft,
          child: PlotButton(
            label: 'Place lodging on map',
            variant: PlotButtonVariant.ghost,
            icon: Icons.hotel_outlined,
            onPressed: !everFetched
                ? null
                : () => _openMap(context, lodgingCandidates),
          ),
        ),
        if (!everFetched)
          Text(
            'Find candidates on the Layers tab first — lodging is filtered '
            'from the same candidate set.',
            style: PlotTypography.small(c.textMuted),
          ),
      ],
    );
  }

  Future<void> _openMap(BuildContext context, List<Candidate> candidates) async {
    final picked = await showDialog<Candidate>(
      context: context,
      builder: (_) => _LodgingMapDialog(candidates: candidates),
    );
    if (picked == null || !mounted) return;
    final node = lodgingNodeFromCandidate(picked, id: _uuid.v4());
    if (node == null) return;
    ref.read(currentTripProvider.notifier).promoteCandidate(widget.day.id, node);
  }
}

/// The map surface behind "Place lodging on map" — [candidates] arrives
/// already filtered by [_LodgingSectionState]'s type chips, so this dialog
/// draws exactly the overlays the Author asked to see and nothing else.
/// Reuses [CandidateMap] (the Curation Workspace's own candidate rendering)
/// rather than a second marker implementation, the same reuse #325's rest-day
/// location redesign calls for.
class _LodgingMapDialog extends StatelessWidget {
  const _LodgingMapDialog({required this.candidates});
  final List<Candidate> candidates;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 640,
        height: 480,
        child: Stack(
          children: [
            CandidateMap(
              candidates: candidates,
              onCandidateTap: (c) => Navigator.pop(context, c),
            ),
            Positioned(
              top: PlotSpacing.s3,
              right: PlotSpacing.s3,
              child: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            if (candidates.isEmpty)
              Positioned(
                left: PlotSpacing.s3,
                bottom: PlotSpacing.s3,
                child: Text(
                  'No lodging of the selected type in the trip area.',
                  style: PlotTypography.small(PlotColors.of(context).textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

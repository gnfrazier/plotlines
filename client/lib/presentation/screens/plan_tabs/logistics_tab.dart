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
            for (final segment in day.segments) ...[
              _SegmentTile(day: day, segment: segment, onOpen: () => onOpenSegment(day.id, segment.id)),
              if (!day.isRest) _AlternatesSection(dayId: day.id, segment: segment),
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

/// The segment tile names its nodes; its alternates get their own section
/// below ([_AlternatesSection]), grouped by the accommodation / branch intent
/// (FR20 [AMENDED v2.0] / C4).
String? _segmentSubtitle(Segment segment) {
  if (segment.nodes.isEmpty) return null;
  return '${segment.nodes.length} node(s)';
}

/// FR20 [AMENDED v2.0] / C4, Flow 11 — the alternate authoring surface. An
/// alternate is a second path on a passage, and it is one of two things: an
/// *accommodation* alternate is the same day at a different effort (the H6
/// bypass/extension a Character may take on their own copy); a *branch* is a
/// story choice carrying its own [Alternate.note], [Alternate.anchorIds],
/// [Alternate.narration], and [Alternate.reveal]. The Author names which one
/// they are making before they draw it, and this surface never blurs the two
/// afterwards — the branch fields are absent on an accommodation editor, not
/// disabled.
///
/// Geometry drawing and re-solve are not here: an alternate is created with an
/// empty line-string ("not drawn yet") and its path is drawn on the Route
/// tab's map, the same seam every other passage geometry uses.
class _AlternatesSection extends ConsumerWidget {
  const _AlternatesSection({required this.dayId, required this.segment});
  final String dayId;
  final Segment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final accommodation = segment.alternates.where((a) => !a.isBranch).toList();
    final branch = segment.alternates.where((a) => a.isBranch).toList();

    // Nothing yet — a single inline affordance, no card. The vocabulary
    // (accommodation vs branch) is chosen in the create dialog, not here.
    if (segment.alternates.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: PlotButton(
          label: 'Add alternate',
          variant: PlotButtonVariant.ghost,
          icon: Icons.alt_route,
          onPressed: () => _addAlternate(context, ref),
        ),
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
            Row(
              children: [
                Text('ALTERNATES', style: PlotTypography.data(c.textMuted)),
                const Spacer(),
                PlotButton(
                  label: 'Add alternate',
                  variant: PlotButtonVariant.ghost,
                  icon: Icons.add,
                  onPressed: () => _addAlternate(context, ref),
                ),
              ],
            ),
            if (accommodation.isNotEmpty) ...[
              const SizedBox(height: PlotSpacing.s2),
              _IntentGroupHeading(
                label: 'ACCOMMODATION',
                caption: 'Same day, different effort',
              ),
              for (final a in accommodation)
                _AlternateRow(dayId: dayId, segment: segment, alternate: a),
            ],
            if (branch.isNotEmpty) ...[
              const SizedBox(height: PlotSpacing.s2),
              _IntentGroupHeading(
                label: 'BRANCH',
                caption: 'Changes what the day contains',
              ),
              for (final a in branch)
                _AlternateRow(dayId: dayId, segment: segment, alternate: a),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _addAlternate(BuildContext context, WidgetRef ref) async {
    final spec = await showDialog<_NewAlternateSpec>(
      context: context,
      builder: (_) => const _NewAlternateDialog(),
    );
    if (spec == null) return;
    final alternate = ref.read(currentTripProvider.notifier).addAlternateToSegment(
          dayId,
          segment.id,
          intent: spec.intent,
          kind: spec.kind,
          label: spec.label,
        );
    if (!context.mounted) return;
    // Straight into the editor — the create dialog only set the vocabulary.
    await _openEditor(context, ref, alternate);
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref, Alternate alternate) {
    return showDialog<void>(
      context: context,
      builder: (_) => _AlternateEditorDialog(
        dayId: dayId,
        segmentId: segment.id,
        alternateId: alternate.id,
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
  const _AlternateRow({required this.dayId, required this.segment, required this.alternate});
  final String dayId;
  final Segment segment;
  final Alternate alternate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final meta = <String>[
      alternate.kind.toUpperCase(),
      if (alternate.isBranch && alternate.anchorIds.isNotEmpty)
        '${alternate.anchorIds.length} ${alternate.anchorIds.length == 1 ? 'anchor' : 'anchors'}',
      if (alternate.isBranch && alternate.narration != null) 'narration',
      if (alternate.isBranch && alternate.reveal != null)
        alternate.reveal == 'on_arrival' ? 'on arrival' : 'always visible',
      if (alternate.geometry.coordinates.length < 2) 'not drawn',
    ];
    return PlotListTile(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _AlternateEditorDialog(
          dayId: dayId,
          segmentId: segment.id,
          alternateId: alternate.id,
        ),
      ),
      title: alternate.label ?? 'Untitled alternate',
      subtitle: meta.join(' · '),
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

/// What [_NewAlternateDialog] returns — the vocabulary moment, said in words
/// (Flow 11 §02): the intent and the shape, before any geometry.
class _NewAlternateSpec {
  const _NewAlternateSpec({required this.intent, required this.kind, required this.label});
  final String intent;
  final String kind;
  final String label;
}

class _NewAlternateDialog extends StatefulWidget {
  const _NewAlternateDialog();

  @override
  State<_NewAlternateDialog> createState() => _NewAlternateDialogState();
}

class _NewAlternateDialogState extends State<_NewAlternateDialog> {
  final _name = TextEditingController();
  String _intent = 'accommodation';
  String _kind = 'bypass';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final named = _name.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text('New alternate', style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Text('What kind of alternate is this?', style: PlotTypography.body(c.textSecondary)),
            const SizedBox(height: PlotSpacing.s2),
            _IntentChoice(
              selected: _intent == 'accommodation',
              title: 'Accommodation',
              body: 'The same day at a different effort. A bypass takes the easiest '
                  'line; an extension adds work. A Character can take it on their own '
                  'copy without changing anyone else’s day.',
              onTap: () => setState(() => _intent = 'accommodation'),
            ),
            const SizedBox(height: PlotSpacing.s2),
            _IntentChoice(
              selected: _intent == 'branch',
              title: 'Branch',
              body: 'A choice that changes what the day contains. The path carries its '
                  'own plot points, its own narration, and its own reveal — the long '
                  'way past the mine, or the direct way home.',
              onTap: () => setState(() => _intent = 'branch'),
            ),
            const SizedBox(height: PlotSpacing.s3),
            Text('SHAPE', style: PlotTypography.data(c.textMuted)),
            const SizedBox(height: PlotSpacing.s1),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'bypass', label: Text('The direct way')),
                ButtonSegment(value: 'extension', label: Text('The long way round')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: PlotSpacing.s3),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name this alternate',
                hintText: 'Toe River road',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: PlotSpacing.s2),
            Text('Drawn on the map next — nothing solved yet.',
                style: PlotTypography.small(c.textMuted)),
            ],
          ),
        ),
      ),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
        PlotButton(
          label: _intent == 'branch' ? 'Create branch' : 'Create alternate',
          onPressed: named
              ? () => Navigator.pop(
                    context,
                    _NewAlternateSpec(
                      intent: _intent,
                      kind: _kind,
                      label: _name.text.trim(),
                    ),
                  )
              : null,
        ),
      ],
    );
  }
}

class _IntentChoice extends StatelessWidget {
  const _IntentChoice({
    required this.selected,
    required this.title,
    required this.body,
    required this.onTap,
  });
  final bool selected;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: PlotRadii.controlShape,
      child: Container(
        padding: const EdgeInsets.all(PlotSpacing.s3),
        decoration: BoxDecoration(
          borderRadius: PlotRadii.controlShape,
          border: Border.all(
            color: selected ? c.primary : c.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? c.primary : c.textMuted,
            ),
            const SizedBox(width: PlotSpacing.s2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(body, style: PlotTypography.small(c.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Flow 11 §03/§04 — one editor, longer for a branch. The four branch fields
/// (note, anchors, narration, reveal) are simply absent while the alternate is
/// an accommodation: the model has no place to put them.
class _AlternateEditorDialog extends ConsumerStatefulWidget {
  const _AlternateEditorDialog({
    required this.dayId,
    required this.segmentId,
    required this.alternateId,
  });
  final String dayId;
  final String segmentId;
  final String alternateId;

  @override
  ConsumerState<_AlternateEditorDialog> createState() => _AlternateEditorDialogState();
}

class _AlternateEditorDialogState extends ConsumerState<_AlternateEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _note;

  Alternate? _find(Trip trip) {
    for (final day in trip.days) {
      if (day.id != widget.dayId) continue;
      for (final s in day.segments) {
        if (s.id != widget.segmentId) continue;
        for (final a in s.alternates) {
          if (a.id == widget.alternateId) return a;
        }
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final a = _find(ref.read(currentTripProvider));
    _name = TextEditingController(text: a?.label ?? '');
    _note = TextEditingController(text: a?.note ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  CurrentTripNotifier get _notifier => ref.read(currentTripProvider.notifier);

  void _patch(Alternate Function(Alternate) f) {
    final current = _find(ref.read(currentTripProvider));
    if (current == null) return;
    _notifier.updateAlternateInSegment(widget.dayId, widget.segmentId, f(current));
  }

  Future<void> _toAccommodation(Alternate a) async {
    if (a.hasBranchContent) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _AlternateConvertPrompt(alternate: a),
      );
      if (ok != true) return;
    }
    _notifier.convertAlternateIntent(
        widget.dayId, widget.segmentId, a.id, 'accommodation');
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final trip = ref.watch(currentTripProvider);
    final a = _find(trip);
    if (a == null) {
      // Deleted underneath the open dialog — nothing to edit.
      return const SizedBox.shrink();
    }

    return AlertDialog(
      title: Row(
        children: [
          PlotBadge(a.isBranch ? 'BRANCH' : 'ACCOMMODATION',
              tone: a.isBranch ? PlotBadgeTone.gold : PlotBadgeTone.slate),
          const SizedBox(width: PlotSpacing.s2),
          Flexible(
            child: Text(a.label ?? 'Untitled alternate',
                style: PlotTypography.title(c.textPrimary), overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name', isDense: true),
                onChanged: (v) => _patch((cur) => v.trim().isEmpty
                    ? cur.copyWith(clearLabel: true)
                    : cur.copyWith(label: v.trim())),
              ),
              const SizedBox(height: PlotSpacing.s3),
              Text('SHAPE', style: PlotTypography.data(c.textMuted)),
              const SizedBox(height: PlotSpacing.s1),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bypass', label: Text('Bypass')),
                  ButtonSegment(value: 'extension', label: Text('Extension')),
                ],
                selected: {a.kind},
                onSelectionChanged: (s) => _patch((cur) => cur.copyWith(kind: s.first)),
              ),
              if (a.isBranch) ...[
                const SizedBox(height: PlotSpacing.s3),
                Text('WHAT IS DIFFERENT ON THIS PATH', style: PlotTypography.data(c.textMuted)),
                const SizedBox(height: PlotSpacing.s1),
                TextField(
                  controller: _note,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'Three miles of the old tramway grade, then the portal itself…',
                    isDense: true,
                  ),
                  onChanged: (v) => _patch((cur) => v.trim().isEmpty
                      ? cur.copyWith(clearNote: true)
                      : cur.copyWith(note: v)),
                ),
                const SizedBox(height: PlotSpacing.s3),
                _BranchAnchors(
                  anchors: trip.anchors,
                  attached: a.anchorIds,
                  onToggle: (id) => _patch((cur) {
                    final next = [...cur.anchorIds];
                    next.contains(id) ? next.remove(id) : next.add(id);
                    return cur.copyWith(anchorIds: next);
                  }),
                ),
                const SizedBox(height: PlotSpacing.s3),
                Text('NARRATION ON THE BRANCH', style: PlotTypography.data(c.textMuted)),
                const SizedBox(height: PlotSpacing.s1),
                Text(
                  a.narration == null
                      ? 'No narration on this branch. Attach it from the narrative editor.'
                      : 'Narration attached.',
                  style: PlotTypography.small(c.textMuted),
                ),
                const SizedBox(height: PlotSpacing.s3),
                Text('REVEAL FOR THIS BRANCH', style: PlotTypography.data(c.textMuted)),
                const SizedBox(height: PlotSpacing.s1),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '', label: Text('Not set')),
                    ButtonSegment(value: 'always_visible', label: Text('Always visible')),
                    ButtonSegment(value: 'on_arrival', label: Text('On arrival')),
                  ],
                  selected: {a.reveal ?? ''},
                  onSelectionChanged: (s) => _patch((cur) => s.first.isEmpty
                      ? cur.copyWith(clearReveal: true)
                      : cur.copyWith(reveal: s.first)),
                ),
                const SizedBox(height: PlotSpacing.s2),
                Text(
                  'The fork stays visible — its content waits. Hazards on this path '
                  'are shown to everyone before the fork, whatever the reveal says.',
                  style: PlotTypography.small(c.textMuted),
                ),
              ] else ...[
                const SizedBox(height: PlotSpacing.s3),
                Text(
                  'This alternate carries nothing of its own — the same day at a '
                  'different effort, so there are no plot points, no narration, and no '
                  'reveal to set. If this path should change what the day contains, it '
                  'is a branch.',
                  style: PlotTypography.small(c.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (a.isBranch)
          PlotButton(
            label: 'Make this an accommodation',
            variant: PlotButtonVariant.ghost,
            onPressed: () => _toAccommodation(a),
          )
        else
          PlotButton(
            label: 'Make this a branch',
            variant: PlotButtonVariant.ghost,
            onPressed: () => _notifier.convertAlternateIntent(
                widget.dayId, widget.segmentId, a.id, 'branch'),
          ),
        PlotButton(label: 'Done', onPressed: () => Navigator.pop(context)),
      ],
    );
  }
}

class _BranchAnchors extends StatelessWidget {
  const _BranchAnchors({
    required this.anchors,
    required this.attached,
    required this.onToggle,
  });
  final List<Anchor> anchors;
  final List<String> attached;
  final void Function(String anchorId) onToggle;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PLOT POINTS ON THIS BRANCH', style: PlotTypography.data(c.textMuted)),
        const SizedBox(height: PlotSpacing.s1),
        if (anchors.isEmpty)
          Text('No anchors in this trip yet. Promote places first, then attach them here.',
              style: PlotTypography.small(c.textMuted))
        else
          for (final anchor in anchors)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: attached.contains(anchor.id),
              onChanged: (_) => onToggle(anchor.id),
              title: Text(anchor.title ?? 'Untitled anchor',
                  style: PlotTypography.body(c.textSecondary)),
            ),
        const SizedBox(height: 2),
        Text('Attached by reference, never copied — edit one and you have edited '
            'the trip’s anchor; detach it and it stays in the trip.',
            style: PlotTypography.small(c.textMuted)),
      ],
    );
  }
}

/// Flow 11 §06 (middle) — turning a branch into an effort option destroys
/// authored work, so it asks first and states the scope. Deliberateness is
/// reserved for destruction (the same shape as [showDayRemovalPrompt]).
class _AlternateConvertPrompt extends StatelessWidget {
  const _AlternateConvertPrompt({required this.alternate});
  final Alternate alternate;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final goes = <String>[
      if (alternate.note != null) 'the note about what is different on this path',
      if (alternate.narration != null) 'the narration on the branch',
      if (alternate.reveal != null) 'the reveal set for this branch',
    ];
    final anchors = alternate.anchorIds.length;
    return AlertDialog(
      title: Text('Turn this branch into an effort option?',
          style: PlotTypography.title(c.textPrimary)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'An accommodation alternate has nowhere to keep what this one is '
              'holding. This goes: ${_join(goes)}.',
              style: PlotTypography.body(c.textSecondary),
            ),
            if (anchors > 0) ...[
              const SizedBox(height: PlotSpacing.s2),
              Text(
                '$anchors ${anchors == 1 ? 'anchor stays' : 'anchors stay'} in the trip, '
                'unattached, and stay findable in the anchors view.',
                style: PlotTypography.small(c.textMuted),
              ),
            ],
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Keep it a branch',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context, false),
        ),
        PlotButton(
          label: 'Give up the content and convert',
          variant: PlotButtonVariant.danger,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }

  static String _join(List<String> parts) {
    if (parts.isEmpty) return 'nothing';
    if (parts.length == 1) return parts.single;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    return '${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
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

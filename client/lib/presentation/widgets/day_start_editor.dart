// Issue #563 — D1's ETA needs a start time. A day's start is stored as a UTC
// instant beside the IANA zone the Author declared it in (`Day.startAt` /
// `Day.startTimezone`); this row and its dialog are where an Author sets it,
// on the day's own wall clock. The conversion lives in `domain/day_start.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../display_format_of.dart';

/// The calendar date [day] falls on: its own `date`, else the trip's start
/// date plus its position, else null — a start time needs a real date, since
/// the zone's offset depends on it.
String? dayCalendarDate(Trip trip, Day day) {
  if (day.date != null) return day.date;
  final start = trip.duration?.startDate == null ? null : DateTime.tryParse(trip.duration!.startDate!);
  if (start == null) return null;
  final d = DateTime.utc(start.year, start.month, start.day + day.index - 1);
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${p2(d.month)}-${p2(d.day)}';
}

/// START row on a route day's Logistics card.
class DayStartRow extends ConsumerWidget {
  const DayStartRow({super.key, required this.trip, required this.day});
  final Trip trip;
  final Day day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final df = displayFormatOf(context, ref);
    final start = dayStart(day);
    final local = start == null ? null : wallClockIn(start.startAt, start.zone);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
      child: Row(
        children: [
          Text('START', style: PlotTypography.data(c.textMuted)),
          const SizedBox(width: PlotSpacing.s3),
          Expanded(
            child: Text(
              local == null ? 'No start time — no arrival estimate' : '${df.formatTime(local)} ${local.timeZoneName} · ${start!.zone}',
              key: ValueKey('day-start-${day.id}'),
              style: local == null ? PlotTypography.small(c.textMuted) : PlotTypography.data(c.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          PlotButton(
            label: local == null ? 'Set start' : 'Edit start',
            variant: PlotButtonVariant.ghost,
            onPressed: () => showDayStartDialog(context, ref, trip: trip, day: day),
          ),
        ],
      ),
    );
  }
}

Future<void> showDayStartDialog(BuildContext context, WidgetRef ref,
    {required Trip trip, required Day day}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _DayStartDialog(trip: trip, day: day),
  );
}

class _DayStartDialog extends ConsumerStatefulWidget {
  const _DayStartDialog({required this.trip, required this.day});
  final Trip trip;
  final Day day;

  @override
  ConsumerState<_DayStartDialog> createState() => _DayStartDialogState();
}

class _DayStartDialogState extends ConsumerState<_DayStartDialog> {
  late int _hour;
  late int _minute;
  late String _zone;
  late final TextEditingController _zoneController;
  final _zoneFocus = FocusNode();
  late final List<String> _zones = knownTimeZones();

  @override
  void initState() {
    super.initState();
    final start = dayStart(widget.day);
    final local = start == null ? null : wallClockIn(start.startAt, start.zone);
    _zone = start?.zone ?? defaultStartZone(widget.trip);
    _hour = local?.hour ?? 8;
    _minute = local == null ? 0 : (local.minute ~/ 5) * 5;
    _zoneController = TextEditingController(text: _zone);
  }

  @override
  void dispose() {
    _zoneController.dispose();
    _zoneFocus.dispose();
    super.dispose();
  }

  void _save(String date) {
    ref.read(currentTripProvider.notifier).setDayStart(widget.day.id,
        startAt: startAtFromLocal(date, _hour, _minute, _zone), timezone: _zone);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final df = displayFormatOf(context, ref);
    final date = dayCalendarDate(widget.trip, widget.day);
    final zoneValid = isKnownTimeZone(_zoneController.text);
    return AlertDialog(
      title: Text('Day ${widget.day.index} start'),
      content: SizedBox(
        width: 360,
        child: date == null
            ? Text('Set the trip dates (or this day\'s date) first — a start time needs a '
                'calendar date, because a time zone\'s offset depends on it.',
                style: PlotTypography.body(c.textSecondary))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(df.formatDate(DateTime.parse(date)), style: PlotTypography.data(c.textSecondary)),
                  const SizedBox(height: PlotSpacing.s3),
                  Row(
                    children: [
                      DropdownButton<int>(
                        key: const ValueKey('day-start-hour'),
                        value: _hour,
                        items: [
                          for (var h = 0; h < 24; h++)
                            DropdownMenuItem(
                                value: h,
                                child: Text(df.formatTime(DateTime(2000, 1, 1, h)),
                                    style: PlotTypography.data(c.textPrimary))),
                        ],
                        onChanged: (h) => setState(() => _hour = h ?? _hour),
                      ),
                      const SizedBox(width: PlotSpacing.s2),
                      Text(':', style: PlotTypography.data(c.textPrimary)),
                      const SizedBox(width: PlotSpacing.s2),
                      DropdownButton<int>(
                        key: const ValueKey('day-start-minute'),
                        value: _minute,
                        items: [
                          for (var m = 0; m < 60; m += 5)
                            DropdownMenuItem(
                                value: m,
                                child: Text(m.toString().padLeft(2, '0'),
                                    style: PlotTypography.data(c.textPrimary))),
                        ],
                        onChanged: (m) => setState(() => _minute = m ?? _minute),
                      ),
                    ],
                  ),
                  const SizedBox(height: PlotSpacing.s3),
                  Text('TIME ZONE', style: PlotTypography.data(c.textMuted)),
                  RawAutocomplete<String>(
                    textEditingController: _zoneController,
                    focusNode: _zoneFocus,
                    optionsBuilder: (value) {
                      final q = value.text.toLowerCase();
                      if (q.isEmpty) return const Iterable<String>.empty();
                      return _zones.where((z) => z.toLowerCase().contains(q)).take(20);
                    },
                    onSelected: (z) => setState(() => _zone = z),
                    fieldViewBuilder: (context, controller, focusNode, onSubmitted) => TextField(
                      key: const ValueKey('day-start-zone'),
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        isDense: true,
                        errorText: zoneValid ? null : 'Not a known time zone',
                      ),
                      onChanged: (v) => setState(() {
                        if (isKnownTimeZone(v)) _zone = v;
                      }),
                    ),
                    optionsViewBuilder: (context, onSelected, options) => Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 2,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220, maxWidth: 360),
                          child: ListView(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            children: [
                              for (final z in options)
                                ListTile(dense: true, title: Text(z), onTap: () => onSelected(z)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        if (dayStart(widget.day) != null)
          TextButton(
            onPressed: () {
              ref.read(currentTripProvider.notifier).setDayStart(widget.day.id);
              Navigator.of(context).pop();
            },
            child: const Text('Clear'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (date != null)
          FilledButton(
            key: const ValueKey('day-start-save'),
            onPressed: zoneValid ? () => _save(date) : null,
            child: const Text('Save'),
          ),
      ],
    );
  }
}

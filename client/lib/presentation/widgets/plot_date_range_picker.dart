// Issue #230 C2 — the trip date range, picked on a desktop surface.
//
// This was Material's `showDateRangePicker`, which is a **mobile** picker:
// a single ~370 px column of vertically-scrolling months, centred in a
// 1918×1078 window with everything else blank. Every finding in C2 followed
// from that one choice plus the stock range styling:
//
//   * a whole range could not be seen without scrolling;
//   * the in-range fill was Material's own secondary container — a dark
//     slate that appears in no Plotlines token file — with the in-range day
//     numbers set dark on top of it;
//   * a range that wrapped a row rendered as two disconnected slabs, because
//     the row-end and row-start cells had no continuation treatment;
//   * today and the selection were both an orange circle, distinguished only
//     by fill;
//   * the header was hard-left over a centred calendar;
//   * the weekday header sat *above* the month label, so `S M T W T F S`
//     read before the month it belonged to;
//   * an unlabelled pencil switched to typed entry with nothing saying so.
//
// So this is a Plotlines picker rather than a themed Material one: two
// months side by side, a light-tint range band that is continuous across row
// wraps, a filled Blaze endpoint against an *outlined* today, one aligned
// header, and each month's weekday row inside that month under its name.
//
// It returns the same `DateTimeRange?` `showDateRangePicker` did, so the
// call site is unchanged apart from the function name.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

/// Picks a start/end date pair. Returns null if the Author cancelled.
Future<DateTimeRange?> showPlotDateRangePicker(
  BuildContext context, {
  required DateTime firstDate,
  required DateTime lastDate,
  DateTimeRange? initialRange,
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (context) => _PlotDateRangeDialog(
      firstDate: DateUtils.dateOnly(firstDate),
      lastDate: DateUtils.dateOnly(lastDate),
      initialRange: initialRange,
    ),
  );
}

class _PlotDateRangeDialog extends StatefulWidget {
  const _PlotDateRangeDialog({
    required this.firstDate,
    required this.lastDate,
    this.initialRange,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTimeRange? initialRange;

  @override
  State<_PlotDateRangeDialog> createState() => _PlotDateRangeDialogState();
}

class _PlotDateRangeDialogState extends State<_PlotDateRangeDialog> {
  DateTime? _start;
  DateTime? _end;

  /// The month drawn in the left pane; the right pane is always the next one.
  late DateTime _leftMonth;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRange;
    _start = initial == null ? null : DateUtils.dateOnly(initial.start);
    _end = initial == null ? null : DateUtils.dateOnly(initial.end);
    final anchor = _start ?? DateUtils.dateOnly(DateTime.now());
    _leftMonth = DateTime(anchor.year, anchor.month);
  }

  DateTime get _rightMonth => DateTime(_leftMonth.year, _leftMonth.month + 1);

  bool get _canPageBack =>
      _leftMonth.isAfter(DateTime(widget.firstDate.year, widget.firstDate.month));

  bool get _canPageForward =>
      _rightMonth.isBefore(DateTime(widget.lastDate.year, widget.lastDate.month));

  /// A tap is either the start of a new range or the end of the one in
  /// progress — the same two-tap model the Material picker uses, so nothing
  /// about *using* it changed, only how it reads.
  void _onDayTapped(DateTime day) {
    setState(() {
      if (_start == null || _end != null) {
        _start = day;
        _end = null;
      } else if (day.isBefore(_start!)) {
        _end = _start;
        _start = day;
      } else {
        _end = day;
      }
    });
  }

  String get _rangeLabel {
    final start = _start;
    if (start == null) return 'Pick the first day';
    final end = _end;
    if (end == null) return '${DateFormat('MMM d').format(start)} — pick the last day';
    final days = end.difference(start).inDays + 1;
    return '${DateFormat('MMM d').format(start)} – ${DateFormat('MMM d, y').format(end)}'
        '   ·   $days ${days == 1 ? 'day' : 'days'}';
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(
          PlotSpacing.s5, PlotSpacing.s4, PlotSpacing.s5, PlotSpacing.s3),
      content: SizedBox(
        width: 660,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // One header, aligned with the calendar beneath it rather than
            // hard-left over a centred grid.
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('TRIP DATES', style: PlotTypography.eyebrow(c.textMuted)),
                      const SizedBox(height: 2),
                      Text(_rangeLabel, style: PlotTypography.title(c.textPrimary)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous month',
                  onPressed: _canPageBack
                      ? () => setState(() =>
                          _leftMonth = DateTime(_leftMonth.year, _leftMonth.month - 1))
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next month',
                  onPressed: _canPageForward
                      ? () => setState(() =>
                          _leftMonth = DateTime(_leftMonth.year, _leftMonth.month + 1))
                      : null,
                ),
              ],
            ),
            const SizedBox(height: PlotSpacing.s4),
            // Two months side by side: a typical trip range is visible whole,
            // with no scrolling and no mental join across a scroll position.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildMonth(_leftMonth)),
                const SizedBox(width: PlotSpacing.s5),
                Expanded(child: _buildMonth(_rightMonth)),
              ],
            ),
            const SizedBox(height: PlotSpacing.s3),
            _Legend(),
          ],
        ),
      ),
      actions: [
        PlotButton(
          label: 'Cancel',
          variant: PlotButtonVariant.ghost,
          onPressed: () => Navigator.pop(context),
        ),
        PlotButton(
          label: 'Use these dates',
          onPressed: (_start == null || _end == null)
              ? null
              : () => Navigator.pop(context, DateTimeRange(start: _start!, end: _end!)),
        ),
      ],
    );
  }

  Widget _buildMonth(DateTime month) {
    final c = PlotColors.of(context);
    final firstWeekday = DateTime(month.year, month.month).weekday % 7; // Sun = 0
    final dayCount = DateUtils.getDaysInMonth(month.year, month.month);
    final today = DateUtils.dateOnly(DateTime.now());

    final cells = <Widget>[
      for (var i = 0; i < firstWeekday; i++) const SizedBox.shrink(),
      for (var d = 1; d <= dayCount; d++)
        Builder(builder: (context) {
          final day = DateTime(month.year, month.month, d);
          final disabled = day.isBefore(widget.firstDate) || day.isAfter(widget.lastDate);
          return _DayCell(
            day: day,
            column: (firstWeekday + d - 1) % 7,
            isStart: _start != null && DateUtils.isSameDay(day, _start),
            isEnd: _end != null && DateUtils.isSameDay(day, _end),
            inRange: _isInRange(day),
            isToday: DateUtils.isSameDay(day, today),
            disabled: disabled,
            onTap: disabled ? null : () => _onDayTapped(day),
          );
        }),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The month names itself first; its own weekday row sits *under* it,
        // inside the month it belongs to.
        Text(DateFormat('MMMM y').format(month), style: PlotTypography.title(c.textPrimary)),
        const SizedBox(height: PlotSpacing.s2),
        Row(
          children: [
            for (final label in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
              Expanded(
                child: Center(
                  child: Text(label, style: PlotTypography.data(c.textMuted)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.15,
          children: cells,
        ),
      ],
    );
  }

  bool _isInRange(DateTime day) {
    final start = _start;
    final end = _end;
    if (start == null || end == null) return false;
    return !day.isBefore(start) && !day.isAfter(end);
  }
}

/// One day. The range band is painted by the cell's own background, extended
/// to the cell edges for a day that is inside the range — so a range that
/// wraps a row reads as one continuous span rather than two slabs, and the
/// two endpoints cap it.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.column,
    required this.isStart,
    required this.isEnd,
    required this.inRange,
    required this.isToday,
    required this.disabled,
    required this.onTap,
  });

  final DateTime day;
  final int column;
  final bool isStart;
  final bool isEnd;
  final bool inRange;
  final bool isToday;
  final bool disabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final isEndpoint = isStart || isEnd;
    // A light Blaze tint, from the palette — not Material's dark secondary
    // container, and light enough to set the day number on in ink.
    final band = c.primary.withValues(alpha: 0.14);
    // The band runs to the cell edge on the side the range continues, and is
    // rounded off where it stops — including at a row's first and last column,
    // which is what makes a wrapped range read as one span.
    final continuesLeft = inRange && !isStart;
    final continuesRight = inRange && !isEnd;

    return Semantics(
      selected: inRange,
      button: onTap != null,
      label: DateFormat('EEEE, MMMM d, y').format(day),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (inRange)
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(
                  left: continuesLeft || column == 0 ? 0 : 3,
                  right: continuesRight || column == 6 ? 0 : 3,
                  top: 3,
                  bottom: 3,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: band,
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(continuesLeft ? 0 : 18),
                      right: Radius.circular(continuesRight ? 0 : 18),
                    ),
                  ),
                ),
              ),
            ),
          Center(
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // Endpoint: a filled Blaze disc.
                  color: isEndpoint ? c.primary : null,
                  // Today: an outline, in the muted ink — never the same hue
                  // as the selection, so the two meanings do not depend on
                  // "filled versus not filled" in one colour.
                  border: isToday && !isEndpoint
                      ? Border.all(color: c.textSecondary, width: 1.5)
                      : null,
                ),
                child: Text(
                  '${day.day}',
                  style: PlotTypography.data(
                    disabled
                        ? c.textMuted.withValues(alpha: 0.5)
                        : isEndpoint
                            ? c.onPrimary
                            : c.textPrimary,
                  ).copyWith(
                    fontSize: 13,
                    letterSpacing: 0,
                    fontWeight: isEndpoint ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    Widget swatch(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: PlotSpacing.s2),
            Text(label, style: PlotTypography.small(c.textMuted)),
          ],
        );

    return Wrap(
      spacing: PlotSpacing.s5,
      runSpacing: PlotSpacing.s2,
      children: [
        swatch(
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.primary),
          ),
          'First and last day',
        ),
        swatch(
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.textSecondary, width: 1.5),
            ),
          ),
          'Today',
        ),
      ],
    );
  }
}

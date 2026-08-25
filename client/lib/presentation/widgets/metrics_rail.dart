// Wireframe screen "01 Route Planner"'s right rail — trip totals, a by-day
// distance breakdown, a by-mode breakdown, and the selected segment's
// elevation profile. This is a straight restoration of what
// `route_planner_screen.dart`'s `_MetricsDashboard` showed before the
// 2026-08-17 wireframe reconciliation replaced that screen with the Trip
// Shell — the Route tab that landed initially dropped this rail entirely
// (a real regression caught in code review, not a deliberate cut).
library;

import 'package:flutter/material.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';

class MetricsRail extends StatelessWidget {
  const MetricsRail({
    super.key,
    required this.trip,
    required this.selectedSegment,
  });
  final Trip trip;
  final Segment? selectedSegment;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    double distance = 0, climb = 0;
    final byDay = <(int, double)>[];
    final byMode = <String, double>{};
    for (final day in trip.days) {
      var dayDistance = 0.0;
      for (final s in day.segments) {
        final d = s.metrics?.distanceM ?? 0;
        distance += d;
        dayDistance += d;
        climb += s.metrics?.climbM ?? s.elevation?.ascentM ?? 0;
        byMode.update(s.mode, (v) => v + d, ifAbsent: () => d);
      }
      if (day.segments.isNotEmpty) byDay.add((day.index, dayDistance));
    }
    final maxDayDistance = byDay.isEmpty
        ? 1.0
        : byDay.map((e) => e.$2).reduce((a, b) => a > b ? a : b);
    final maxModeDistance = byMode.isEmpty
        ? 1.0
        : byMode.values.reduce((a, b) => a > b ? a : b);
    final samples = _normalize(
      selectedSegment?.elevation?.samples ?? const <double>[],
    );

    return Container(
      width: 308,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PlotSpacing.s4,
              PlotSpacing.s4,
              PlotSpacing.s4,
              PlotSpacing.s3,
            ),
            child: Text(
              'PLANNING METRICS',
              style: PlotTypography.data(
                c.textPrimary,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _StatCard(
                          label: 'TRIP DISTANCE',
                          value: '${(distance / 1000).toStringAsFixed(1)} km',
                        ),
                      ),
                      const SizedBox(width: PlotSpacing.s2),
                      Expanded(
                        child: _StatCard(
                          label: 'TOTAL CLIMB',
                          value: '↑ ${climb.toStringAsFixed(0)} m',
                        ),
                      ),
                    ],
                  ),
                  if (byDay.isNotEmpty) ...[
                    const SizedBox(height: PlotSpacing.s4),
                    Text(
                      'BY DAY',
                      style: PlotTypography.data(
                        c.textMuted,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: PlotSpacing.s2),
                    for (final (index, dist) in byDay)
                      _BarRow(
                        label: 'Day $index',
                        fraction: maxDayDistance <= 0
                            ? 0
                            : dist / maxDayDistance,
                        valueLabel: '${(dist / 1000).toStringAsFixed(1)} km',
                        color: c.primary,
                      ),
                  ],
                  if (byMode.isNotEmpty) ...[
                    const SizedBox(height: PlotSpacing.s4),
                    Text(
                      'BY MODE',
                      style: PlotTypography.data(
                        c.textMuted,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: PlotSpacing.s2),
                    for (final entry in byMode.entries)
                      _BarRow(
                        label: entry.key,
                        fraction: maxModeDistance <= 0
                            ? 0
                            : entry.value / maxModeDistance,
                        valueLabel:
                            '${(entry.value / 1000).toStringAsFixed(1)} km',
                        color: c.success,
                      ),
                  ],
                  const SizedBox(height: PlotSpacing.s4),
                  Text(
                    'ELEVATION',
                    style: PlotTypography.data(
                      c.textMuted,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: PlotSpacing.s2),
                  if (samples.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: PlotSpacing.s4,
                      ),
                      child: Text(
                        'Select a segment to see its elevation profile',
                        style: PlotTypography.small(c.textMuted),
                      ),
                    )
                  else
                    ElevationProfile(
                      samples: samples,
                      height: 90,
                      startLabel: '0',
                      endLabel: selectedSegment?.metrics?.distanceM == null
                          ? null
                          : '${(selectedSegment!.metrics!.distanceM! / 1000).toStringAsFixed(1)} km',
                    ),
                  if (selectedSegment != null &&
                      selectedSegment!.via.isNotEmpty &&
                      selectedSegment!.shape != 'point_to_point') ...[
                    const SizedBox(height: PlotSpacing.s4),
                    Text(
                      'VIA-ANCHOR ROUTE',
                      style: PlotTypography.data(
                        c.textMuted,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: PlotSpacing.s2),
                    _ViaAnchorSummary(segment: selectedSegment!),
                  ],
                  const SizedBox(height: PlotSpacing.s3),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<double> _normalize(List<double> samples) {
    if (samples.isEmpty) return const [];
    final maxV = samples.reduce((a, b) => a > b ? a : b);
    final minV = samples.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);
    return samples.map((v) => (v - minV) / range).toList();
  }
}

/// A9/FR8a — the via-anchor AC an Author cannot see just by looking at the
/// map: did the route actually reach every via-anchor and close back on
/// itself (a genuine loop, not an out-and-back), and how much road did that
/// cost it twice? `overlapFarFrac` is the number that matters — road re-ridden
/// out in the corridor rather than on a short spur into a via-anchor's own
/// locality (`overlapNearFrac`), which is the expected "lollipop" shape and
/// not a defect.
class _ViaAnchorSummary extends StatelessWidget {
  const _ViaAnchorSummary({required this.segment});
  final Segment segment;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final hitVia = segment.solve?.hitVia;
    final closed = segment.solve?.closed;
    final farFrac = segment.metrics?.overlapFarFrac;
    final nearFrac = segment.metrics?.overlapNearFrac;

    final rows = <String>[
      '${segment.via.length == 1 ? 'Via-anchor reached' : 'Via-anchors reached'}: '
          '${hitVia == null ? 'unknown' : (hitVia ? 'yes' : 'no')}',
      'Returns to start: ${closed == null ? 'unknown' : (closed ? 'yes' : 'no')}',
      if (farFrac != null) 'Road ridden twice: ${(farFrac * 100).toStringAsFixed(0)}%',
      if (nearFrac != null && nearFrac > 0)
        '— near a via-anchor: ${(nearFrac * 100).toStringAsFixed(0)}%',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(row, style: PlotTypography.small(c.textSecondary)),
          ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return PlotCard(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: PlotTypography.data(c.textMuted).copyWith(fontSize: 9),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: PlotTypography.data(
              c.textPrimary,
            ).copyWith(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.fraction,
    required this.valueLabel,
    required this.color,
  });
  final String label;
  final double fraction;
  final String valueLabel;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(label, style: PlotTypography.data(c.textSecondary)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: PlotRadii.controlShape,
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: c.surfaceSunk,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: PlotSpacing.s2),
          SizedBox(
            width: 52,
            child: Text(
              valueLabel,
              textAlign: TextAlign.right,
              style: PlotTypography.data(c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

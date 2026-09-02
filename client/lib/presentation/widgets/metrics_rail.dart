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

import '../../data/sidecar_manager.dart' show CapabilityStatus;
import '../../domain/domain.dart';
import 'error_states.dart' show CapabilityWarmingNotice;

class MetricsRail extends StatelessWidget {
  const MetricsRail({
    super.key,
    required this.trip,
    required this.selectedSegment,
    required this.elevationCapability,
    this.composeItinerary,
  });
  final Trip trip;
  final Segment? selectedSegment;

  /// E3 / FR39 / FR117 / FR118 (issue #214) — the active day's compose-mode
  /// places-first itinerary (`/days/compose`, captured by
  /// `composeAuthoritative` into `composeItineraryProvider`), when that day is
  /// in compose mode and its spine resolved. Rendered as its own section,
  /// distinct from the explore-mode by-day / elevation readout above.
  final ComposeItinerary? composeItinerary;

  /// FR121/N2 — `climb`/the elevation profile below are both derived from
  /// node elevation the graph never carries until this capability is ready
  /// (`ensure_graph` bakes in no elevation; see `graph/regions.py`), so
  /// showing a bare "↑ 0 m" while it's still loading (or, today, fixed
  /// not-configured pending #148) would read as a real measurement rather
  /// than "unknown." This rail states the honest reason instead.
  final CapabilityStatus elevationCapability;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final elevationReady = elevationCapability.ready;
    double distance = 0, climb = 0;
    final byDay = <(int, double, bool)>[];
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
      // FR19 / C3 — "reflected in the dashboard": the same per-mode breach
      // set the day timeline strip's chip already renders, so the two
      // surfaces can never disagree about which day ran short or long.
      if (day.segments.isNotEmpty) {
        byDay.add((day.index, dayDistance, computeDayLimitBreaches(day).isNotEmpty));
      }
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

    // D1 / FR31 / FR16 (issue #213) — the FR16 moving-time model over the trip
    // as it stands. `build_dashboard` on `/trips/split` is authoritative; this
    // client mirror keeps the panel populated between saves, the same role
    // `rollUpTrip` fills for the plain distance sums. ETA needs a start time the
    // trip payload does not carry yet, so `TripDashboard.fromTrip` never sets
    // it — the row renders only when the server path supplied one.
    final dashboard = TripDashboard.fromTrip(trip);
    final tripMovingS = dashboard.tripTotal.total?.movingTimeS;

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
                          value: elevationReady ? '↑ ${climb.toStringAsFixed(0)} m' : '↑ —',
                          muted: !elevationReady,
                        ),
                      ),
                    ],
                  ),
                  if (!elevationReady) ...[
                    const SizedBox(height: PlotSpacing.s2),
                    CapabilityWarmingNotice(
                      capabilityLabel: 'Elevation',
                      status: elevationCapability,
                    ),
                  ],
                  if (byDay.isNotEmpty) ...[
                    const SizedBox(height: PlotSpacing.s4),
                    Text(
                      'BY DAY',
                      style: PlotTypography.data(
                        c.textMuted,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: PlotSpacing.s2),
                    for (final (index, dist, breached) in byDay)
                      _BarRow(
                        label: 'Day $index',
                        fraction: maxDayDistance <= 0
                            ? 0
                            : dist / maxDayDistance,
                        valueLabel: '${(dist / 1000).toStringAsFixed(1)} km',
                        color: breached ? c.warning : c.primary,
                        breached: breached,
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
                  if (tripMovingS != null) ...[
                    const SizedBox(height: PlotSpacing.s4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _StatCard(
                            label: 'MOVING TIME',
                            value: _formatDuration(tripMovingS),
                          ),
                        ),
                        const SizedBox(width: PlotSpacing.s2),
                        Expanded(
                          child: _StatCard(
                            label: 'EST. ARRIVAL',
                            value: dashboard.tripEta == null
                                ? '—'
                                : _formatEta(dashboard.tripEta!),
                            muted: dashboard.tripEta == null,
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: PlotSpacing.s2),
                      child: Text(
                        dashboard.paceSource == paceCustom
                            ? 'Pace: custom'
                            : 'Pace: system default',
                        style: PlotTypography.small(c.textMuted),
                      ),
                    ),
                  ],
                  if (composeItinerary != null) ...[
                    const SizedBox(height: PlotSpacing.s4),
                    _ComposeItinerarySection(itinerary: composeItinerary!),
                  ],
                  const SizedBox(height: PlotSpacing.s4),
                  Text(
                    'ELEVATION',
                    style: PlotTypography.data(
                      c.textMuted,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: PlotSpacing.s2),
                  if (!elevationReady)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: PlotSpacing.s4,
                      ),
                      child: CapabilityWarmingNotice(
                        capabilityLabel: 'Elevation profile',
                        status: elevationCapability,
                      ),
                    )
                  else if (samples.isEmpty)
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

/// FR16 moving/elapsed time as `4h 20m` / `45m` / `0m` — never a fudged number,
/// so it rounds to the whole minute the pace model can actually stand behind.
String _formatDuration(double seconds) {
  final totalMinutes = (seconds / 60).round();
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  return h == 0 ? '${m}m' : '${h}h ${m}m';
}

/// An ETA stamp (`2026-09-01T14:30:00Z` from `build_dashboard`) as `14:30`.
/// Falls back to the raw stamp if it is not the shape the model emits.
String _formatEta(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final t = parsed.toUtc();
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
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

/// E3 / FR39 / FR117 / FR118 (issue #214) — the compose-mode planning readout:
/// the curated places *are* the route, so this leads with the ordered stops and
/// the passages between them, and reports the day's length as an outcome
/// (A0a: never a constraint, never a conflict). Deliberately its own section,
/// not folded into the explore-mode by-day bars above — a composed day is
/// organised around its places, not a target distance.
class _ComposeItinerarySection extends StatelessWidget {
  const _ComposeItinerarySection({required this.itinerary});
  final ComposeItinerary itinerary;

  static String _km(double? m) =>
      m == null ? '—' : '${(m / 1000).toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final distance = itinerary.distance;
    final dev = distance.deviationM;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'COMPOSE ITINERARY',
          style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: PlotSpacing.s2),
        _StatCard(label: 'DAY DISTANCE', value: _km(distance.realisedM)),
        if (distance.hasTarget && dev != null) ...[
          const SizedBox(height: PlotSpacing.s2),
          Text(
            dev.abs() < 1
                ? 'On the ${_km(distance.targetM)} you had in mind.'
                : '${_km(dev.abs())} ${dev > 0 ? 'over' : 'under'} the '
                    '${_km(distance.targetM)} you had in mind.',
            style: PlotTypography.small(c.textSecondary),
          ),
          if (distance.dispositions.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Options: ${distance.dispositions.join(' · ')}',
                style: PlotTypography.small(c.textMuted),
              ),
            ),
        ],
        const SizedBox(height: PlotSpacing.s3),
        for (var i = 0; i < itinerary.stops.length; i++) ...[
          _ComposeStopRow(stop: itinerary.stops[i]),
          if (i < itinerary.legs.length)
            _ComposeLegRow(leg: itinerary.legs[i]),
        ],
      ],
    );
  }
}

class _ComposeStopRow extends StatelessWidget {
  const _ComposeStopRow({required this.stop});
  final ComposeStop stop;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '${stop.order + 1}',
              style: PlotTypography.data(c.textMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        stop.title ?? 'Untitled place',
                        style: PlotTypography.small(c.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (stop.hazard) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.warning_amber_rounded, size: 13, color: c.warning),
                    ],
                    if (stop.hasUnrevealedNarrative) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.lock_outline, size: 12, color: c.textMuted),
                    ],
                  ],
                ),
                if (stop.roles.isNotEmpty)
                  Text(
                    stop.roles.map((r) => r.toUpperCase()).join(' · '),
                    style: PlotTypography.small(c.textMuted).copyWith(fontSize: 9),
                  ),
              ],
            ),
          ),
          const SizedBox(width: PlotSpacing.s2),
          Text(
            _ComposeItinerarySection._km(stop.distanceAlongM),
            style: PlotTypography.data(c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ComposeLegRow extends StatelessWidget {
  const _ComposeLegRow({required this.leg});
  final ComposeLeg leg;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 18, bottom: 2, top: 1),
      child: Row(
        children: [
          Icon(Icons.more_vert, size: 12, color: c.textMuted),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              leg.mode,
              style: PlotTypography.small(c.textMuted),
            ),
          ),
          Text(
            _ComposeItinerarySection._km(leg.distanceM),
            style: PlotTypography.data(c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.muted = false});
  final String label;
  final String value;

  /// FR121/N2 — true while the value behind this card (e.g. climb, gated on
  /// elevation readiness) isn't real yet, so the number reads as "not
  /// available" rather than a normally-styled measurement.
  final bool muted;

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
              muted ? c.textMuted : c.textPrimary,
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
    this.breached = false,
  });
  final String label;
  final double fraction;
  final String valueLabel;
  final Color color;

  /// FR19 / C3 — "reflected in the dashboard": true when the day this row
  /// represents breaches one of its per-mode limits (`computeDayLimitBreaches`).
  final bool breached;

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
          if (breached) ...[
            Icon(Icons.warning_amber_rounded, size: 14, color: c.warning),
            const SizedBox(width: 2),
          ],
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

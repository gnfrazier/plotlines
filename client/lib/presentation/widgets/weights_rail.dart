// Wireframe screen "01 Route Planner"'s left rail — weights, bands, shape,
// target distance, via-nodes, and the diagnose/regenerate actions for the
// segment focused on the Route tab (`selectedSegmentProvider`), always
// visible rather than behind a modal sheet the way this was built before
// the 2026-08-17 wireframe reconciliation (that modal was
// `segment_editor_sheet.dart`, now deleted — this rail is its full
// replacement, container and all, including A6's diagnose flow, which now
// opens `conflict_dialog.dart`'s real modal instead of an inline card).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/routing_client.dart';
import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import '../../state/providers.dart';
import '../../state/trip_bbox_provider.dart';
import 'conflict_dialog.dart';
import 'error_states.dart';

const _surfaceClasses = ['paved', 'gravel', 'singletrack'];
const _attributes = [
  'distance_m', 'climb_m', 'descent_m', 'traffic', 'unpaved_frac', 'scenic_frac', 'salience',
];
const _shapes = ['loop', 'out_and_back', 'point_to_point'];
const _shapeLabels = {'loop': 'LOOP', 'out_and_back': 'OUT-BACK', 'point_to_point': 'P2P'};

class WeightsRail extends ConsumerStatefulWidget {
  const WeightsRail({super.key, required this.dayId, required this.segment});
  final String dayId;
  final Segment? segment;

  @override
  ConsumerState<WeightsRail> createState() => _WeightsRailState();
}

class _WeightsRailState extends ConsumerState<WeightsRail> {
  bool _regenerating = false;
  bool _diagnosing = false;
  bool _addingBand = false;
  String? _error;

  @override
  void didUpdateWidget(covariant WeightsRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segment?.id != widget.segment?.id) {
      // Only the *display* resets here — an in-flight request for the old
      // segment still runs to completion (its `finally` clears these same
      // flags when it resolves), it just no longer owns this rail's UI.
      setState(() {
        _error = null;
        _regenerating = false;
        _diagnosing = false;
        _addingBand = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final segment = widget.segment;
    if (segment == null) {
      return Container(
        width: 308,
        decoration: BoxDecoration(border: Border(right: BorderSide(color: c.border))),
        padding: const EdgeInsets.all(PlotSpacing.s5),
        child: Text(
          'Select a segment on the map or in Logistics to edit its weights.',
          style: PlotTypography.body(c.textMuted),
        ),
      );
    }
    final weights = segment.weights ?? WeightProfile(name: 'custom');
    void setWeights(WeightProfile w) => ref
        .read(currentTripProvider.notifier)
        .updateSegmentWeights(widget.dayId, segment.id, w);
    final mode = ref.watch(dayPlanningModeProvider(widget.dayId));

    return Container(
      width: 308,
      decoration: BoxDecoration(border: Border(right: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(PlotSpacing.s4, PlotSpacing.s4, PlotSpacing.s4, PlotSpacing.s3),
            child: Text('ROUTE WEIGHTS',
                style: PlotTypography.data(c.textPrimary).copyWith(fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // FR117/A0's AC — the day's mode, always the first thing in
                  // the rail: visible without scrolling on open, and the
                  // switch itself (ARCH §7.7: nothing about the segment is
                  // destroyed by tapping the other mode).
                  _PlanningModeToggle(dayId: widget.dayId, mode: mode, segment: segment),
                  const SizedBox(height: PlotSpacing.s2),
                  Text(
                    mode == PlanningMode.explore
                        ? 'Explore — weights and bands define the search space; the distance below is a constraint.'
                        : 'Compose — the spine below defines the route; weights only flavor the connections between its places.',
                    style: PlotTypography.small(c.textMuted),
                  ),
                  const SizedBox(height: PlotSpacing.s4),
                  WeightSlider(
                    // A1's AC: "'peaks' terminology in UI" — matches the
                    // "Peaks — climbing" / "Cars — traffic tolerance"
                    // pattern in `Flow 4 - Explore and compose.dc.html`.
                    label: 'Peaks — climbing',
                    hint: 'flat ↔ indifferent ↔ seek peaks',
                    value: weights.climbing ?? 2.5,
                    onChanged: (v) => setWeights(weights.copyWith(climbing: v)),
                  ),
                  WeightSlider(
                    // A2's AC: "'cars' terminology" — matches the "Peaks —
                    // climbing" / "Cars — traffic tolerance" pattern in
                    // `Flow 4 - Explore and compose.dc.html`.
                    label: 'Cars — traffic tolerance',
                    hint: 'avoid cars ↔ indifferent ↔ seek cars',
                    value: weights.traffic ?? 2.5,
                    onChanged: (v) => setWeights(weights.copyWith(traffic: v)),
                  ),
                  for (final cls in _surfaceClasses)
                    WeightSlider(
                      label: 'Surface — $cls',
                      hint: 'avoid ↔ indifferent ↔ seek',
                      value: weights.surface[cls] ?? 2.5,
                      onChanged: (v) => setWeights(weights.withSurfaceClass(cls, v)),
                    ),
                  WeightSlider(
                    // FR5/A4's AC: a single salience bias, no POI-type control —
                    // layer selection already says what matters (FR97); this
                    // says only how much to seek it. ARCH §7.7: inactive in
                    // compose, where the promoted anchors are already the spine.
                    label: 'Interest — good places',
                    hint: mode == PlanningMode.explore
                        ? 'indifferent ↔ seek high-salience places'
                        : 'indifferent ↔ seek high-salience places · inactive in compose — the spine already says what\'s here',
                    value: weights.interest ?? 0.0,
                    onChanged: mode == PlanningMode.compose
                        ? null
                        : (v) => setWeights(weights.copyWith(interest: v)),
                  ),
                  const SizedBox(height: PlotSpacing.s4),
                  if (mode == PlanningMode.explore) ...[
                    Text('BANDS', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: PlotSpacing.s1),
                    Text('Acceptance range on a realised attribute — never on the weight itself.',
                        style: PlotTypography.small(c.textMuted)),
                    const SizedBox(height: PlotSpacing.s2),
                    for (final band in segment.bands)
                      BandRow(
                        key: ValueKey(band.attribute),
                        band: band,
                        onChanged: (updated) => ref.read(currentTripProvider.notifier).updateSegmentBands(
                              widget.dayId,
                              segment.id,
                              [for (final b in segment.bands) if (b.attribute == band.attribute) updated else b],
                            ),
                        onRemove: () => ref.read(currentTripProvider.notifier).updateSegmentBands(
                              widget.dayId,
                              segment.id,
                              segment.bands.where((b) => b != band).toList(),
                            ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: PlotButton(
                        label: _addingBand ? 'Adding…' : 'Add band',
                        variant: PlotButtonVariant.ghost,
                        icon: Icons.add,
                        onPressed: _addingBand ? null : () => _addBand(segment),
                      ),
                    ),
                  ] else ...[
                    Text(
                      'Bands aren\'t edited here — the route reaches every place in the '
                      'spine regardless. Any band you set is only used below, to report '
                      'how the realized day compares to it.',
                      style: PlotTypography.small(c.textMuted),
                    ),
                    const SizedBox(height: PlotSpacing.s4),
                    // Unbounded, like BANDS above — compose *is* the
                    // POI-spine trip (FR39/FR117), with no cap on how many
                    // places it reaches, so this lives in the scrollable
                    // middle rather than the fixed bottom rail the way the
                    // capped 1-2-item explore VIA badges still do.
                    Text('SPINE', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: PlotSpacing.s1),
                    Text(
                      'The promoted places this route reaches, in order.',
                      style: PlotTypography.small(c.textMuted),
                    ),
                    const SizedBox(height: PlotSpacing.s2),
                    _SpineEditor(dayId: widget.dayId, segment: segment),
                    const SizedBox(height: PlotSpacing.s4),
                    _ComposeDeviationPanel(dayId: widget.dayId, segment: segment),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: PlotSpacing.s3),
                    ConflictBanner(explanation: _error!),
                  ],
                  const SizedBox(height: PlotSpacing.s3),
                ],
              ),
            ),
          ),
          // shape + distance + via — the wireframe's bottom rail section.
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
            padding: const EdgeInsets.all(PlotSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SHAPE', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: PlotSpacing.s2),
                Wrap(
                  spacing: PlotSpacing.s2,
                  children: [
                    for (final s in _shapes)
                      ChoiceChip(
                        label: Text(_shapeLabels[s]!),
                        selected: segment.shape == s,
                        onSelected: (_) => ref
                            .read(currentTripProvider.notifier)
                            .updateSegmentShape(widget.dayId, segment.id, s),
                      ),
                  ],
                ),
                const SizedBox(height: PlotSpacing.s3),
                _TargetDistanceField(dayId: widget.dayId, segment: segment, mode: mode),
                if (mode == PlanningMode.explore && segment.via.isNotEmpty) ...[
                  const SizedBox(height: PlotSpacing.s3),
                  Text('VIA (A9)', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: PlotSpacing.s2),
                  Wrap(
                    spacing: PlotSpacing.s2,
                    runSpacing: PlotSpacing.s2,
                    children: [
                      for (var i = 0; i < segment.via.length; i++)
                        PlotBadge('Via ${i + 1}', tone: PlotBadgeTone.slate),
                    ],
                  ),
                ],
                if (segment.solve?.stale ?? false) ...[
                  const SizedBox(height: PlotSpacing.s3),
                  const PlotBadge('Stale — needs re-solve', tone: PlotBadgeTone.gold, solid: true),
                ],
                if (_composeNeedsTarget(mode, segment)) ...[
                  const SizedBox(height: PlotSpacing.s3),
                  Text(
                    'Loop always solves to a target distance, which compose doesn\'t set — '
                    'pick out-and-back or point-to-point, or switch back to explore.',
                    style: PlotTypography.small(c.danger),
                  ),
                ],
                const SizedBox(height: PlotSpacing.s3),
                Row(
                  children: [
                    if (mode == PlanningMode.explore) ...[
                      Expanded(
                        child: PlotButton(
                          label: segment.bands.isEmpty
                              ? 'Add a band to diagnose'
                              : (_diagnosing ? 'Diagnosing…' : 'Diagnose'),
                          variant: PlotButtonVariant.secondary,
                          onPressed: (_diagnosing || segment.bands.isEmpty || segment.metrics?.distanceM == null)
                              ? null
                              : () => _diagnose(segment),
                        ),
                      ),
                      const SizedBox(width: PlotSpacing.s2),
                    ],
                    Expanded(
                      child: PlotButton(
                        label: _regenerating ? 'Re-solving…' : 'Regenerate',
                        onPressed: (_regenerating || _composeNeedsTarget(mode, segment))
                            ? null
                            : () => _regenerate(segment, mode),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _regenerate(Segment segment, PlanningMode mode) async {
    setState(() {
      _regenerating = true;
      _error = null;
    });
    try {
      await ref
          .read(currentTripProvider.notifier)
          .regenerateSegment(widget.dayId, segment.id, mode: mode);
    } on RoutingException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  /// A5's AC — a new band opens on the range this region can actually
  /// deliver, probed from the graph (SPIKE-03: fixed defaults were feasible
  /// 22.2% of the time, envelope-derived 100%), never on a blank/guessed
  /// pair. `probe_envelope` only knows how to search loop shapes around a
  /// target distance (`routing/search.py`'s own scope), so anything else
  /// falls back to the prior blank-band behavior rather than failing —
  /// probing is a convenience default, not a requirement, and an Author can
  /// always type a band by hand.
  Future<void> _addBand(Segment segment) async {
    final attr = _attributes.firstWhere(
      (a) => !segment.bands.any((b) => b.attribute == a),
      orElse: () => _attributes.first,
    );
    double? lo, hi;
    final targetM = segment.targetDistance?.valueM ?? segment.metrics?.distanceM;
    if (segment.shape == 'loop' && segment.start != null && targetM != null) {
      setState(() {
        _addingBand = true;
        _error = null;
      });
      try {
        final client = ref.read(routingClientProvider);
        final bbox = ref.read(tripBboxProvider);
        if (bbox != null) {
          final region = await client.ensureRegion(bbox.bboxWsen);
          final envelope = await client.envelope(
            region: region,
            start: segment.start!,
            targetM: targetM,
            via: segment.via,
          );
          final range = envelope[attr];
          if (range != null && range.length == 2) {
            lo = range[0];
            hi = range[1];
          }
        }
      } on RoutingException catch (e) {
        setState(() => _error = e.message);
      } finally {
        if (mounted) setState(() => _addingBand = false);
      }
    }
    ref.read(currentTripProvider.notifier).updateSegmentBands(
          widget.dayId,
          segment.id,
          [...segment.bands, Band(attribute: attr, min: lo, max: hi, source: lo == null && hi == null ? null : 'envelope')],
        );
  }

  /// Loop always requires `target_m` server-side (`service/app.py`), which
  /// contradicts compose's "no target, length is an outcome" (ARCH §7.7) —
  /// this is the one shape/mode combination Regenerate must refuse rather
  /// than send a request the sidecar will 422.
  static bool _composeNeedsTarget(PlanningMode mode, Segment segment) =>
      mode == PlanningMode.compose && segment.shape == 'loop';

  Future<void> _diagnose(Segment segment) async {
    setState(() {
      _diagnosing = true;
      _error = null;
    });
    try {
      final client = ref.read(routingClientProvider);
      final bbox = ref.read(tripBboxProvider);
      if (bbox == null) {
        throw StateError('no trip bbox — draw the trip area (FR120) before diagnosing bands');
      }
      final region = await client.ensureRegion(bbox.bboxWsen);
      final jobId = await client.submitDiagnose(
        region: region,
        start: segment.start!,
        targetM: segment.metrics!.distanceM!,
        bands: segment.bands,
        via: segment.via,
      );
      Diagnosis? result;
      while (result == null) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        result = await client.pollDiagnose(jobId);
      }
      if (!mounted) return;
      await showConflictDialog(
        context,
        explanation: result.explanation,
        viaImplicated: result.viaImplicated,
        relaxations: [
          for (final r in result.relaxations)
            RelaxationOffer(from: r.from, to: r.to, tradeOff: r.tradeOff, metric: r.metric),
        ],
        onApplyRelaxation: (offer) => _applyRelaxation(segment, offer),
      );
    } on RoutingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _diagnosing = false);
    }
  }

  void _applyRelaxation(Segment segment, RelaxationOffer offer) {
    if (offer.metric == null) return;
    final updated = [
      for (final b in segment.bands)
        if (b.attribute == offer.metric) _widenBandFromDescription(b, offer.to) else b,
    ];
    ref.read(currentTripProvider.notifier).updateSegmentBands(widget.dayId, segment.id, updated);
  }

  /// The relaxation's `to` is a human-readable description
  /// (`Band.describe()` on the Python side), not structured data — see
  /// `diagnosis.dart`'s doc comment. Applying it re-widens the stored band
  /// to admit the value it names rather than re-parsing that prose; where a
  /// number can't be recovered, the band is left unbounded on that side
  /// rather than guessed at.
  Band _widenBandFromDescription(Band band, String description) {
    final match = RegExp(r'[-+]?[0-9]*\.?[0-9]+').firstMatch(description.replaceAll(',', ''));
    if (match == null) return band;
    final value = double.tryParse(match.group(0)!);
    if (value == null) return band;
    final isPercent = description.contains('%');
    final scaled = isPercent ? value / 100.0 : value;
    return band.copyWith(min: band.min == null ? null : scaled, max: band.max == null ? null : scaled);
  }
}

class _TargetDistanceField extends ConsumerStatefulWidget {
  const _TargetDistanceField({required this.dayId, required this.segment, required this.mode});
  final String dayId;
  final Segment segment;

  /// FR117/A0's AC — the field's meaning visibly changes with the day's
  /// posture: a constraint the Author sets in explore, a reported outcome
  /// they can only read in compose.
  final PlanningMode mode;

  @override
  ConsumerState<_TargetDistanceField> createState() => _TargetDistanceFieldState();
}

class _TargetDistanceFieldState extends ConsumerState<_TargetDistanceField> {
  late final _controller = TextEditingController(
    text: widget.segment.targetDistance == null
        ? ''
        : (widget.segment.targetDistance!.valueM / 1000).toStringAsFixed(1),
  );
  String? _lastSegmentId;
  PlanningMode? _lastMode;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    // Re-sync the field on a different segment, or on a compose->explore
    // transition — the latter because switching modes is the one non-typing
    // way this value changes underneath the field (FR119's backfill in
    // `_PlanningModeToggle`), and there is no in-progress edit to clobber
    // coming out of compose, which shows no text field at all.
    if (_lastSegmentId != widget.segment.id ||
        (_lastMode == PlanningMode.compose && widget.mode == PlanningMode.explore)) {
      _controller.text = widget.segment.targetDistance == null
          ? ''
          : (widget.segment.targetDistance!.valueM / 1000).toStringAsFixed(1);
    }
    _lastSegmentId = widget.segment.id;
    _lastMode = widget.mode;

    // ARCH §7.7 / FR118 — in compose the distance is a reported outcome,
    // never an editable constraint, so this reads the realized metric
    // straight off the segment rather than the authored (and, in compose,
    // unsent) target-distance field.
    if (widget.mode == PlanningMode.compose) {
      final distanceM = widget.segment.metrics?.distanceM;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s3),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: PlotRadii.controlShape,
          color: c.surfaceSunk,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DISTANCE — REPORTED OUTCOME',
                      style: PlotTypography.small(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: PlotSpacing.s1),
                  Text(
                    distanceM == null ? '—' : '${(distanceM / 1000).toStringAsFixed(1)} km',
                    style: PlotTypography.data(c.textPrimary).copyWith(fontSize: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return TextField(
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'Target distance (km)',
        isDense: true,
        border: const OutlineInputBorder(),
        helperText: widget.segment.shape == 'point_to_point'
            ? 'Advisory for point-to-point — start/end govern the actual route'
            : 'The constraint Generate/Regenerate solves toward',
        helperStyle: PlotTypography.small(c.textMuted),
      ),
      onSubmitted: (text) {
        final km = double.tryParse(text);
        ref.read(currentTripProvider.notifier).updateSegmentTargetDistance(
              widget.dayId,
              widget.segment.id,
              km == null ? null : km * 1000,
            );
      },
    );
  }
}

class WeightSlider extends StatelessWidget {
  const WeightSlider({super.key, required this.label, required this.hint, required this.value, required this.onChanged});
  final String label;
  final String hint;
  final double value;

  /// Null disables the slider — compose mode's "inactive" weights (ARCH
  /// §7.7's `interest` row) rather than hiding them outright, so the
  /// Author's authored value stays visible even while it isn't sent.
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600))),
              Text(value.toStringAsFixed(1), style: PlotTypography.data(c.textSecondary)),
            ],
          ),
          Slider(value: value, min: 0, max: 5, divisions: 20, onChanged: onChanged),
          Text(hint, style: PlotTypography.small(c.textMuted)),
        ],
      ),
    );
  }
}

class BandRow extends StatefulWidget {
  const BandRow({super.key, required this.band, required this.onChanged, required this.onRemove});
  final Band band;
  final ValueChanged<Band> onChanged;
  final VoidCallback onRemove;

  @override
  State<BandRow> createState() => _BandRowState();
}

class _BandRowState extends State<BandRow> {
  late final _min = TextEditingController(text: widget.band.min?.toString() ?? '');
  late final _max = TextEditingController(text: widget.band.max?.toString() ?? '');

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(widget.band.copyWith(
      min: double.tryParse(_min.text),
      max: double.tryParse(_max.text),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
      child: PlotCard(
        sunk: true,
        padding: const EdgeInsets.all(PlotSpacing.s3),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(widget.band.attribute, style: PlotTypography.data(c.textPrimary)),
            ),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _min,
                decoration: const InputDecoration(hintText: 'min', isDense: true),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onChanged: (_) => _emit(),
              ),
            ),
            const SizedBox(width: PlotSpacing.s2),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _max,
                decoration: const InputDecoration(hintText: 'max', isDense: true),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onChanged: (_) => _emit(),
              ),
            ),
            IconButton(icon: const Icon(Icons.close, size: 16), onPressed: widget.onRemove),
          ],
        ),
      ),
    );
  }
}

/// FR117/A0 — the day's planning-mode switch, always visible at the top of
/// the rail (the AC's "the current mode is always visible"). Doubles as
/// FR119's switch action itself: tapping the other mode chip *is*
/// "promote to compose" / "loosen the spine to explore" — there is no
/// separate confirmation step because nothing about the segment is
/// destroyed by switching (ARCH §7.7: the two postures share every
/// authored field a segment already has).
class _PlanningModeToggle extends ConsumerWidget {
  const _PlanningModeToggle({required this.dayId, required this.mode, required this.segment});
  final String dayId;
  final PlanningMode mode;
  final Segment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void select(PlanningMode next) {
      if (next == mode) return;
      // FR119 "compose -> loosen the spine -> explore": hand compose's
      // discovered length back as explore's starting constraint, but only
      // when the Author never authored one of their own — an existing
      // explore target is never overwritten, and a no-op set would mark
      // the segment stale for nothing.
      if (next == PlanningMode.explore && segment.targetDistance == null) {
        final backfill = loosenedTargetDistanceM(
          existingTarget: segment.targetDistance,
          realizedDistanceM: segment.metrics?.distanceM,
        );
        if (backfill != null) {
          ref
              .read(currentTripProvider.notifier)
              .updateSegmentTargetDistance(dayId, segment.id, backfill);
        }
      }
      ref.read(dayPlanningModeProvider(dayId).notifier).state = next;
    }

    return Wrap(
      spacing: PlotSpacing.s2,
      children: [
        ChoiceChip(
          label: const Text('EXPLORE'),
          selected: mode == PlanningMode.explore,
          onSelected: (_) => select(PlanningMode.explore),
        ),
        ChoiceChip(
          label: const Text('COMPOSE'),
          selected: mode == PlanningMode.compose,
          onSelected: (_) => select(PlanningMode.compose),
        ),
      ],
    );
  }
}

/// Compose mode's spine — an ordered, editable list of the trip's promoted
/// [Anchor]s this segment's route must reach (`Segment.via`; ARCH §7.7's
/// "the promoted anchor set"). Explore's own via-node UI (map taps in
/// `new_route_screen.dart`, capped at 1-2 per A9 MVP) is untouched; this is
/// compose's counterpart for a day that has moved past initial creation,
/// with no cap since compose *is* the POI-spine trip (FR39/FR117).
class _SpineEditor extends ConsumerWidget {
  const _SpineEditor({required this.dayId, required this.segment});
  final String dayId;
  final Segment segment;

  static bool _sameCoord(Coord a, Coord b) => a[0] == b[0] && a[1] == b[1];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final anchors = ref.watch(currentTripProvider.select((t) => t.anchors));
    String labelFor(Coord coord) {
      for (final a in anchors) {
        if (_sameCoord(a.coord, coord)) return a.title ?? 'Untitled place';
      }
      return 'Custom point';
    }

    final available = [
      for (final a in anchors)
        if (!segment.via.any((v) => _sameCoord(v, a.coord))) a,
    ];
    void setVia(List<Coord> via) =>
        ref.read(currentTripProvider.notifier).updateSegmentVia(dayId, segment.id, via);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (segment.via.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
            child: Text('No places in the spine yet — add one below.',
                style: PlotTypography.small(c.textMuted)),
          )
        else
          for (var i = 0; i < segment.via.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
              child: PlotCard(
                sunk: true,
                padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
                child: Row(
                  children: [
                    Text('${i + 1}.', style: PlotTypography.data(c.textMuted)),
                    const SizedBox(width: PlotSpacing.s2),
                    Expanded(
                      child: Text(labelFor(segment.via[i]), style: PlotTypography.body(c.textPrimary)),
                    ),
                    IconButton(
                      tooltip: 'Move earlier in the spine',
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      onPressed: i == 0
                          ? null
                          : () {
                              final via = [...segment.via];
                              final item = via.removeAt(i);
                              via.insert(i - 1, item);
                              setVia(via);
                            },
                    ),
                    IconButton(
                      tooltip: 'Move later in the spine',
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      onPressed: i == segment.via.length - 1
                          ? null
                          : () {
                              final via = [...segment.via];
                              final item = via.removeAt(i);
                              via.insert(i + 1, item);
                              setVia(via);
                            },
                    ),
                    IconButton(
                      tooltip: 'Remove from the spine',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        final via = [...segment.via]..removeAt(i);
                        setVia(via);
                      },
                    ),
                  ],
                ),
              ),
            ),
        if (available.isNotEmpty)
          PopupMenuButton<Anchor>(
            tooltip: 'Add a promoted place to the spine',
            onSelected: (a) => setVia([...segment.via, a.coord]),
            itemBuilder: (context) => [
              for (final a in available) PopupMenuItem(value: a, child: Text(a.title ?? 'Untitled place')),
            ],
            child: const _SpineAddChip(),
          )
        else if (anchors.isEmpty)
          Text('Promote a place first (Curation) to add it to this spine.',
              style: PlotTypography.small(c.textMuted)),
      ],
    );
  }
}

/// The established "`PopupMenuButton` wraps a plain-looking chip" idiom
/// (`new_route_screen.dart`'s primary-mode "+ Add") — the menu button
/// supplies its own tap handling around whatever child it's given, so this
/// stays visually a normal, enabled control despite carrying no `onTap`
/// itself.
class _SpineAddChip extends StatelessWidget {
  const _SpineAddChip();

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        border: Border.all(color: c.border),
        borderRadius: PlotRadii.controlShape,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add, size: 16, color: c.textSecondary),
          const SizedBox(width: PlotSpacing.s2),
          Text('Add place', style: PlotTypography.data(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// FR118/A0a — "See what my chosen places make." Compose mode's
/// editing-decision surface: realized distance, elevation and time,
/// compared against any stated band (`statedDistanceBand`), presented with
/// A0a's five affordances. Deliberately **not** `ConflictBanner` or
/// `conflict_dialog.dart` — those are A6's error/relaxation surface, and
/// FR118/FR140a are explicit that a compose-mode deviation must never
/// route through it: this is its own card, always positive-toned framing,
/// no "diagnose" step.
class _ComposeDeviationPanel extends ConsumerWidget {
  const _ComposeDeviationPanel({required this.dayId, required this.segment});
  final String dayId;
  final Segment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final realizedDistanceM = segment.metrics?.distanceM;
    if (segment.via.isEmpty || realizedDistanceM == null) {
      return Text(
        'Add places to the spine and regenerate to see what they make of the day.',
        style: PlotTypography.small(c.textMuted),
      );
    }

    final band = statedDistanceBand(segment);
    final deviates = distanceDeviatesFromBand(realizedDistanceM, band);
    final acceptedAt = ref.watch(composeDeviationAcceptedProvider(segment.id));
    final accepted = isDeviationAccepted(
      acceptedAtDistanceM: acceptedAt,
      realizedDistanceM: realizedDistanceM,
    );

    final climbM = segment.elevation?.ascentM ?? segment.metrics?.climbM;
    final moving = _formatHoursMinutes(segment.metrics?.movingTimeS);
    final elapsed = _formatHoursMinutes(segment.metrics?.elapsedTimeS);
    final detailParts = [
      if (climbM != null) '${climbM.toStringAsFixed(0)} m of climb',
      if (moving != null) '$moving moving',
      if (elapsed != null) '$elapsed elapsed',
    ];

    final statusColor = deviates == null ? c.textPrimary : (deviates ? c.warning : c.success);

    return Container(
      padding: const EdgeInsets.all(PlotSpacing.s3),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: PlotRadii.controlShape,
        color: c.surfaceSunk,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('REALIZED DAY', style: PlotTypography.small(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: PlotSpacing.s2),
          Text(
            composeDeviationHeadline(
              placeCount: segment.via.length,
              realizedDistanceM: realizedDistanceM,
              band: band,
            ),
            style: PlotTypography.body(statusColor).copyWith(fontWeight: FontWeight.w600),
          ),
          if (detailParts.isNotEmpty) ...[
            const SizedBox(height: PlotSpacing.s1),
            Text(detailParts.join(', '), style: PlotTypography.small(c.textMuted)),
          ],
          if (accepted) ...[
            const SizedBox(height: PlotSpacing.s2),
            const PlotBadge('Accepted', tone: PlotBadgeTone.slate),
          ],
          const SizedBox(height: PlotSpacing.s3),
          Wrap(
            spacing: PlotSpacing.s2,
            runSpacing: PlotSpacing.s2,
            children: [
              _DropAnchorAction(dayId: dayId, segment: segment),
              _MoveToAnotherDayAction(dayId: dayId, segment: segment),
              if (segment.via.length >= 2)
                PlotButton(
                  label: 'Split the day',
                  variant: PlotButtonVariant.ghost,
                  onPressed: () => ref
                      .read(currentTripProvider.notifier)
                      .splitDayAt(dayId, segment.id, (segment.via.length / 2).ceil()),
                ),
              if (deviates == true && band != null)
                PlotButton(
                  label: 'Widen the band',
                  variant: PlotButtonVariant.ghost,
                  onPressed: () => ref.read(currentTripProvider.notifier).updateSegmentBands(
                        dayId,
                        segment.id,
                        [
                          for (final b in segment.bands)
                            if (b.attribute == 'distance_m')
                              widenBandToAdmit(b, realizedDistanceM)
                            else
                              b,
                        ],
                      ),
                ),
              PlotButton(
                label: accepted ? 'Accepted' : 'Accept',
                variant: PlotButtonVariant.ghost,
                onPressed: accepted
                    ? null
                    : () => ref
                        .read(composeDeviationAcceptedProvider(segment.id).notifier)
                        .state = realizedDistanceM,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String? _formatHoursMinutes(double? seconds) {
    if (seconds == null) return null;
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    return '$h:${m.toString().padLeft(2, '0')}';
  }
}

/// A0a — "drop an anchor," the one affordance that never needs a second
/// selection: [_ComposeDeviationPanel] only renders once the spine is
/// non-empty, so there is always at least one via-anchor to offer here.
class _DropAnchorAction extends ConsumerWidget {
  const _DropAnchorAction({required this.dayId, required this.segment});
  final String dayId;
  final Segment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anchors = ref.watch(currentTripProvider.select((t) => t.anchors));
    String labelFor(Coord coord) {
      for (final a in anchors) {
        if (a.coord[0] == coord[0] && a.coord[1] == coord[1]) return a.title ?? 'Untitled place';
      }
      return 'Custom point';
    }

    return PopupMenuButton<Coord>(
      tooltip: 'Drop an anchor from the spine',
      onSelected: (coord) => ref.read(currentTripProvider.notifier).updateSegmentVia(
            dayId,
            segment.id,
            [for (final v in segment.via) if (!(v[0] == coord[0] && v[1] == coord[1])) v],
          ),
      itemBuilder: (context) => [
        for (final v in segment.via) PopupMenuItem(value: v, child: Text(labelFor(v))),
      ],
      child: const _GhostActionChip(label: 'Drop an anchor…'),
    );
  }
}

/// A0a — "move one to another day." Only days that already carry a segment
/// are offered (`CurrentTripNotifier.moveViaToDay`'s own constraint) — an
/// empty day has nowhere for the anchor to land. Hides itself entirely
/// when the trip has no such day, rather than showing a menu with nothing
/// in it.
class _MoveToAnotherDayAction extends ConsumerWidget {
  const _MoveToAnotherDayAction({required this.dayId, required this.segment});
  final String dayId;
  final Segment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(currentTripProvider);
    String labelFor(Coord coord) {
      for (final a in trip.anchors) {
        if (a.coord[0] == coord[0] && a.coord[1] == coord[1]) return a.title ?? 'Untitled place';
      }
      return 'Custom point';
    }

    final otherDays = [
      for (final d in trip.days)
        if (d.id != dayId && d.segments.isNotEmpty) d,
    ];
    if (otherDays.isEmpty) return const SizedBox.shrink();

    final options = [
      for (final coord in segment.via)
        for (final d in otherDays) (coord: coord, day: d),
    ];

    return PopupMenuButton<({Coord coord, Day day})>(
      tooltip: 'Move a spine anchor to another day',
      onSelected: (choice) => ref
          .read(currentTripProvider.notifier)
          .moveViaToDay(dayId, segment.id, choice.coord, choice.day.id),
      itemBuilder: (context) => [
        for (final o in options)
          PopupMenuItem(value: o, child: Text('Move ${labelFor(o.coord)} to day ${o.day.index}')),
      ],
      child: const _GhostActionChip(label: 'Move to another day…'),
    );
  }
}

/// Shared ghost-styled `PopupMenuButton` child for [_DropAnchorAction] and
/// [_MoveToAnotherDayAction] — same idiom as [_SpineAddChip], sized like a
/// [PlotButton] ghost variant so the affordance row reads as one set of
/// equal-weight actions rather than two different control styles.
class _GhostActionChip extends StatelessWidget {
  const _GhostActionChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: PlotRadii.controlShape,
      ),
      child: Text(label, style: PlotTypography.data(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

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
import '../../state/providers.dart';
import 'conflict_dialog.dart';
import 'error_states.dart';

const _surfaceClasses = ['paved', 'gravel', 'singletrack'];
const _attributes = [
  'distance_m', 'climb_m', 'descent_m', 'traffic', 'unpaved_frac', 'scenic_frac', 'poi_density',
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
  String? _error;

  @override
  void didUpdateWidget(covariant WeightsRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segment?.id != widget.segment?.id) {
      setState(() => _error = null);
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
                  WeightSlider(
                    label: 'Climbing',
                    hint: 'flat ↔ indifferent ↔ seek peaks',
                    value: weights.climbing ?? 2.5,
                    onChanged: (v) => setWeights(weights.copyWith(climbing: v)),
                  ),
                  WeightSlider(
                    label: 'Traffic',
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
                    label: 'POI density',
                    hint: 'sparse ↔ dense',
                    value: weights.poiDensity ?? 2.5,
                    onChanged: (v) => setWeights(weights.copyWith(poiDensity: v)),
                  ),
                  const SizedBox(height: PlotSpacing.s4),
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
                      label: 'Add band',
                      variant: PlotButtonVariant.ghost,
                      icon: Icons.add,
                      onPressed: () {
                        final attr = _attributes.firstWhere(
                          (a) => !segment.bands.any((b) => b.attribute == a),
                          orElse: () => _attributes.first,
                        );
                        ref.read(currentTripProvider.notifier).updateSegmentBands(
                              widget.dayId,
                              segment.id,
                              [...segment.bands, Band(attribute: attr, min: null, max: null)],
                            );
                      },
                    ),
                  ),
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
                _TargetDistanceField(dayId: widget.dayId, segment: segment),
                if (segment.via.isNotEmpty) ...[
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
                const SizedBox(height: PlotSpacing.s3),
                Row(
                  children: [
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
                    Expanded(
                      child: PlotButton(
                        label: _regenerating ? 'Re-solving…' : 'Regenerate',
                        onPressed: _regenerating ? null : () => _regenerate(segment),
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

  Future<void> _regenerate(Segment segment) async {
    setState(() {
      _regenerating = true;
      _error = null;
    });
    try {
      await ref.read(currentTripProvider.notifier).regenerateSegment(widget.dayId, segment.id);
    } on RoutingException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  Future<void> _diagnose(Segment segment) async {
    setState(() {
      _diagnosing = true;
      _error = null;
    });
    try {
      final client = ref.read(routingClientProvider);
      final jobId = await client.submitDiagnose(
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
  const _TargetDistanceField({required this.dayId, required this.segment});
  final String dayId;
  final Segment segment;

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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    // Re-sync the field when a different segment is selected — cheap check,
    // avoids clobbering an in-progress edit on every rebuild.
    if (_lastSegmentId != widget.segment.id) {
      _lastSegmentId = widget.segment.id;
      _controller.text = widget.segment.targetDistance == null
          ? ''
          : (widget.segment.targetDistance!.valueM / 1000).toStringAsFixed(1);
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
            : null,
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
  final ValueChanged<double> onChanged;

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

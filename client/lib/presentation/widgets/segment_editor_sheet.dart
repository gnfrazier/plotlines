// A1-A6 — weight sliders, band controls, and A6's conflict diagnosis, all
// against one open segment. This is wireframe screens "01 Route Planner"'s
// per-segment editing surface and "02 Constraint Conflict" combined into one
// sheet, because on the live backend today they're the same interaction:
// `/segments/generate` (routing/solve.py) takes weights but no bands or
// target distance, so there is no live "generate under bands, fail, offer
// relaxations" loop to separate into its own screen yet — that loop is
// `routing/loops.py` + `/segments/diagnose`'s real trigger, and loop
// generation isn't wired to an endpoint (see new_route_screen.dart's note).
//
// What IS live and wired here: `/segments/envelope` and `/segments/diagnose`
// both exist and work against a start point + target distance + bands, so
// "Diagnose" below runs a real, honest A6 conflict check using the
// segment's current realised distance as the target — a genuine relaxation
// negotiation, just not one that today's Generate button triggers automatically.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/routing_client.dart';
import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/providers.dart';
import '../widgets/error_states.dart';

Future<void> showSegmentEditorSheet(
  BuildContext context, {
  required String dayId,
  required Segment segment,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _SegmentEditor(
        dayId: dayId,
        segmentId: segment.id,
        scrollController: scrollController,
      ),
    ),
  );
}

const _surfaceClasses = ['paved', 'gravel', 'singletrack'];
const _attributes = [
  'distance_m', 'climb_m', 'descent_m', 'traffic', 'unpaved_frac', 'scenic_frac', 'poi_density',
];

class _SegmentEditor extends ConsumerStatefulWidget {
  const _SegmentEditor({required this.dayId, required this.segmentId, required this.scrollController});
  final String dayId;
  final String segmentId;
  final ScrollController scrollController;

  @override
  ConsumerState<_SegmentEditor> createState() => _SegmentEditorState();
}

class _SegmentEditorState extends ConsumerState<_SegmentEditor> {
  bool _regenerating = false;
  bool _diagnosing = false;
  Diagnosis? _diagnosis;
  String? _generateError;

  Segment get _segment {
    final trip = ref.read(currentTripProvider);
    final day = trip.days.firstWhere((d) => d.id == widget.dayId);
    return day.segments.firstWhere((s) => s.id == widget.segmentId);
  }

  WeightProfile get _weights => _segment.weights ?? WeightProfile(name: 'custom');

  void _setWeights(WeightProfile w) => ref
      .read(currentTripProvider.notifier)
      .updateSegmentWeights(widget.dayId, widget.segmentId, w);

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    // Rebuild on trip changes so slider values track the store.
    ref.watch(currentTripProvider);
    final segment = _segment;
    final weights = _weights;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(PlotSpacing.s5),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Edit segment', style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 20)),
              ),
              if (segment.solve?.stale ?? false)
                const PlotBadge('Stale — needs re-solve', tone: PlotBadgeTone.gold, solid: true),
            ],
          ),
          const SizedBox(height: PlotSpacing.s2),
          Text(
            '${segment.mode} · ${segment.shape.replaceAll('_', ' ')}'
            '${segment.metrics?.distanceM != null ? ' · ${(segment.metrics!.distanceM! / 1000).toStringAsFixed(1)} km' : ''}',
            style: PlotTypography.data(c.textSecondary),
          ),
          const SizedBox(height: PlotSpacing.s5),

          _SectionHeader('WEIGHTS (FR2-FR5)'),
          _WeightSlider(
            label: 'Climbing',
            hint: 'flat ↔ indifferent ↔ seek peaks',
            value: weights.climbing ?? 2.5,
            onChanged: (v) => _setWeights(weights.copyWith(climbing: v)),
          ),
          _WeightSlider(
            label: 'Traffic',
            hint: 'avoid cars ↔ indifferent ↔ seek cars',
            value: weights.traffic ?? 2.5,
            onChanged: (v) => _setWeights(weights.copyWith(traffic: v)),
          ),
          for (final cls in _surfaceClasses)
            _WeightSlider(
              label: 'Surface — $cls',
              hint: 'avoid ↔ indifferent ↔ seek',
              value: weights.surface[cls] ?? 2.5,
              onChanged: (v) => _setWeights(weights.withSurfaceClass(cls, v)),
            ),
          _WeightSlider(
            label: 'POI density',
            hint: 'sparse ↔ dense',
            value: weights.poiDensity ?? 2.5,
            onChanged: (v) => _setWeights(weights.copyWith(poiDensity: v)),
          ),

          const SizedBox(height: PlotSpacing.s5),
          _SectionHeader('BANDS (FR6 / A5)'),
          Text(
            'Acceptance range on a realised attribute — never on the weight itself.',
            style: PlotTypography.small(c.textSecondary),
          ),
          const SizedBox(height: PlotSpacing.s3),
          for (final band in segment.bands)
            _BandRow(
              key: ValueKey(band.attribute),
              band: band,
              onChanged: (updated) => ref.read(currentTripProvider.notifier).updateSegmentBands(
                    widget.dayId,
                    widget.segmentId,
                    [for (final b in segment.bands) if (b.attribute == band.attribute) updated else b],
                  ),
              onRemove: () => ref.read(currentTripProvider.notifier).updateSegmentBands(
                    widget.dayId,
                    widget.segmentId,
                    segment.bands.where((b) => b != band).toList(),
                  ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: PlotButton(
              label: 'Add band',
              variant: PlotButtonVariant.ghost,
              icon: Icons.add,
              onPressed: () => _addBand(segment),
            ),
          ),

          if (_generateError != null) ...[
            const SizedBox(height: PlotSpacing.s3),
            ConflictBanner(explanation: _generateError!),
          ],
          if (_diagnosis != null) ...[
            const SizedBox(height: PlotSpacing.s3),
            ConflictBanner(
              explanation: _diagnosis!.explanation,
              viaImplicated: _diagnosis!.viaImplicated,
              relaxations: [
                for (final r in _diagnosis!.relaxations)
                  RelaxationOffer(from: r.from, to: r.to, tradeOff: r.tradeOff, metric: r.metric),
              ],
              onApplyRelaxation: (offer) => _applyRelaxation(segment, offer),
            ),
          ],

          const SizedBox(height: PlotSpacing.s5),
          Row(
            children: [
              Expanded(
                child: PlotButton(
                  label: segment.bands.isEmpty
                      ? 'Add a band to diagnose'
                      : (_diagnosing ? 'Diagnosing…' : 'Diagnose bands'),
                  variant: PlotButtonVariant.secondary,
                  onPressed: (_diagnosing || segment.bands.isEmpty || segment.metrics?.distanceM == null)
                      ? null
                      : () => _diagnose(segment),
                ),
              ),
              const SizedBox(width: PlotSpacing.s3),
              Expanded(
                child: PlotButton(
                  label: _regenerating ? 'Re-solving…' : 'Regenerate route',
                  onPressed: _regenerating ? null : () => _regenerate(segment),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _addBand(Segment segment) {
    final attr = _attributes.firstWhere((a) => !segment.bands.any((b) => b.attribute == a),
        orElse: () => _attributes.first);
    ref.read(currentTripProvider.notifier).updateSegmentBands(
          widget.dayId,
          widget.segmentId,
          [...segment.bands, Band(attribute: attr, min: null, max: null)],
        );
  }

  Future<void> _regenerate(Segment segment) async {
    setState(() {
      _regenerating = true;
      _generateError = null;
      _diagnosis = null;
    });
    try {
      await ref.read(currentTripProvider.notifier).regenerateSegment(widget.dayId, widget.segmentId);
    } on RoutingException catch (e) {
      setState(() => _generateError = e.message);
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  Future<void> _diagnose(Segment segment) async {
    setState(() {
      _diagnosing = true;
      _diagnosis = null;
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
      if (mounted) setState(() => _diagnosis = result);
    } on RoutingException catch (e) {
      if (mounted) setState(() => _generateError = e.message);
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
    ref.read(currentTripProvider.notifier).updateSegmentBands(widget.dayId, widget.segmentId, updated);
    setState(() => _diagnosis = null);
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
      child: Text(text, style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

class _WeightSlider extends StatelessWidget {
  const _WeightSlider({required this.label, required this.hint, required this.value, required this.onChanged});
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

class _BandRow extends StatefulWidget {
  const _BandRow({super.key, required this.band, required this.onChanged, required this.onRemove});
  final Band band;
  final ValueChanged<Band> onChanged;
  final VoidCallback onRemove;

  @override
  State<_BandRow> createState() => _BandRowState();
}

class _BandRowState extends State<_BandRow> {
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
              width: 72,
              child: TextField(
                controller: _min,
                decoration: const InputDecoration(hintText: 'min', isDense: true),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onChanged: (_) => _emit(),
              ),
            ),
            const SizedBox(width: PlotSpacing.s2),
            SizedBox(
              width: 72,
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

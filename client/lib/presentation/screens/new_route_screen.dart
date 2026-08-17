// Wireframe screen "00 New Route" — mode, shape, theme and start/end/via
// picked before the first solve. `client/design/README.md` flags this
// wireframe as predating A7 (shape selector beyond "loop") and A9 (via-node
// UI); both are built here rather than carried over missing.
//
// Known gap (see docs/Plotlines_MVP_Scope_and_Setup.md open questions):
// `/segments/generate` (service/app.py) only ever calls
// `routing.solve.generate_segment`, which solves a point-to-point/via path.
// Loop closure and out-and-back live in `routing/loops.py` but are not wired
// to the endpoint yet. Loop/out-and-back are still selectable and stored on
// the segment (FR7/A7's AC: shape is selectable independently of weights) —
// the same "schema ships, solver catches up" precedent MVP §1.3 sets for
// paddling — but Generate is disabled with an honest inline note until then.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/routing_client.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import '../map/tap_to_pick_map.dart';
import '../widgets/error_states.dart';

class NewRouteScreen extends ConsumerStatefulWidget {
  const NewRouteScreen({super.key});
  @override
  ConsumerState<NewRouteScreen> createState() => _NewRouteScreenState();
}

class _NewRouteScreenState extends ConsumerState<NewRouteScreen> {
  String _mode = 'cycling';
  String _shape = 'point_to_point';
  String _theme = 'balanced';
  List<double>? _start;
  List<double>? _end;
  final List<List<double>> _via = [];
  bool _generating = false;
  String? _error;

  static const _modes = ['cycling', 'hiking', 'paddling', 'transit'];
  static const _shapes = ['loop', 'out_and_back', 'point_to_point'];
  static const _themes = ['balanced', 'quiet_scenic', 'fastest', 'gravel'];

  bool get _shapeIsSolvable => _shape == 'point_to_point';

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New route')),
      body: Row(
        children: [
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(PlotSpacing.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionLabel('MODE'),
                  Wrap(
                    spacing: PlotSpacing.s2,
                    children: [
                      for (final m in _modes)
                        ChoiceChip(
                          label: Text(m),
                          selected: _mode == m,
                          onSelected: (_) => setState(() => _mode = m),
                        ),
                    ],
                  ),
                  if (_mode == 'paddling')
                    Padding(
                      padding: const EdgeInsets.only(top: PlotSpacing.s2),
                      child: Text(
                        'Paddling routing lands in a later release (Leg 3) — the mode '
                        'is saveable now, but Generate will not produce a paddling route yet.',
                        style: PlotTypography.small(c.textMuted),
                      ),
                    ),
                  const SizedBox(height: PlotSpacing.s5),
                  _SectionLabel('SHAPE'),
                  Wrap(
                    spacing: PlotSpacing.s2,
                    children: [
                      for (final s in _shapes)
                        ChoiceChip(
                          label: Text(s.replaceAll('_', ' ')),
                          selected: _shape == s,
                          onSelected: (_) => setState(() => _shape = s),
                        ),
                    ],
                  ),
                  if (!_shapeIsSolvable)
                    Padding(
                      padding: const EdgeInsets.only(top: PlotSpacing.s2),
                      child: Text(
                        'Loop and out-and-back closure isn\'t wired into the sidecar '
                        'yet — point-to-point routes today.',
                        style: PlotTypography.small(c.textMuted),
                      ),
                    ),
                  const SizedBox(height: PlotSpacing.s5),
                  _SectionLabel('THEME'),
                  Wrap(
                    spacing: PlotSpacing.s2,
                    children: [
                      for (final t in _themes)
                        ChoiceChip(
                          label: Text(t.replaceAll('_', ' ')),
                          selected: _theme == t,
                          onSelected: (_) => setState(() => _theme = t),
                        ),
                    ],
                  ),
                  const SizedBox(height: PlotSpacing.s5),
                  _SectionLabel('START / END / VIA'),
                  Text(
                    'Tap the map to place points. First tap sets start, second sets '
                    'end; further taps add via-nodes (A9 — 1–2 supported).',
                    style: PlotTypography.small(c.textSecondary),
                  ),
                  const SizedBox(height: PlotSpacing.s2),
                  _PointList(start: _start, end: _end, via: _via, onClear: () => setState(() {
                    _start = null;
                    _end = null;
                    _via.clear();
                  })),
                  if (_error != null) ...[
                    const SizedBox(height: PlotSpacing.s3),
                    NoDataBanner(onChooseAnotherArea: () => Navigator.pop(context)),
                  ],
                  const SizedBox(height: PlotSpacing.s5),
                  PlotButton(
                    label: _generating ? 'Generating…' : 'Generate route',
                    expand: true,
                    onPressed: (_start == null || _end == null || _generating || !_shapeIsSolvable)
                        ? null
                        : _generate,
                  ),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          Expanded(
            child: TapToPickMap(
              points: [?_start, ..._via, ?_end],
              onTap: (point) => setState(() {
                if (_start == null) {
                  _start = point;
                } else if (_end == null) {
                  _end = point;
                } else if (_via.length < 2) {
                  _via.add(point);
                }
              }),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final targetDay = ref.read(plannerTargetDayIdProvider);
      await ref.read(currentTripProvider.notifier).generateSegment(
            dayId: targetDay,
            start: _start!,
            end: _end!,
            via: _via,
            mode: _mode,
            theme: _theme,
          );
      ref.read(plannerTargetDayIdProvider.notifier).state = null;
      if (mounted) context.go('/planner');
    } on RoutingException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
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

class _PointList extends StatelessWidget {
  const _PointList({required this.start, required this.end, required this.via, required this.onClear});
  final List<double>? start;
  final List<double>? end;
  final List<List<double>> via;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    String fmt(List<double> p) => '${p[1].toStringAsFixed(4)}, ${p[0].toStringAsFixed(4)}';
    return PlotCard(
      sunk: true,
      padding: const EdgeInsets.all(PlotSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Start: ${start == null ? '—' : fmt(start!)}', style: PlotTypography.data(c.textPrimary)),
          Text('End: ${end == null ? '—' : fmt(end!)}', style: PlotTypography.data(c.textPrimary)),
          for (var i = 0; i < via.length; i++)
            Text('Via ${i + 1}: ${fmt(via[i])}', style: PlotTypography.data(c.textPrimary)),
          if (start != null)
            Align(
              alignment: Alignment.centerRight,
              child: PlotButton(label: 'Clear points', variant: PlotButtonVariant.ghost, onPressed: onClear),
            ),
        ],
      ),
    );
  }
}

// Wireframe screen "00 New Route" — mode, shape, theme and start/end/via
// picked before the first solve. `client/design/README.md` flags this
// wireframe as predating A7 (shape selector beyond "loop") and A9 (via-node
// UI); both are built here rather than carried over missing.
//
// All three shapes are live: `/segments/generate` routes to
// `routing/loops.py`'s `generate_loop`/`generate_out_and_back` for the two
// loop-family shapes and `routing/solve.py`'s `generate_segment` for
// point-to-point (MVP doc §8, resolved this session).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/routing_client.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import '../../state/providers.dart';
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
  final _targetKmController = TextEditingController();
  final _searchController = TextEditingController();
  bool _generating = false;
  bool _searching = false;
  String? _error;
  List<GeocodeResult> _searchResults = const [];

  static const _modes = ['cycling', 'hiking', 'paddling', 'transit'];
  static const _shapes = ['loop', 'out_and_back', 'point_to_point'];
  static const _themes = ['balanced', 'quiet_scenic', 'fastest', 'gravel'];

  @override
  void dispose() {
    _targetKmController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  double? get _targetM {
    final km = double.tryParse(_targetKmController.text);
    return km == null ? null : km * 1000;
  }

  bool get _canGenerate {
    if (_start == null) return false;
    return switch (_shape) {
      'loop' => _targetM != null,
      'out_and_back' => _end != null || _targetM != null,
      _ => _end != null,
    };
  }

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
                  _SectionLabel('LOCATION SEARCH'),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: const InputDecoration(
                            hintText: 'Search a place to set start…',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _search(),
                        ),
                      ),
                      IconButton(
                        icon: _searching
                            ? const SizedBox(
                                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.search),
                        onPressed: _searching ? null : _search,
                      ),
                    ],
                  ),
                  for (final r in _searchResults)
                    PlotListTile(
                      title: r.label,
                      onTap: () => setState(() {
                        _start = r.coord;
                        _searchResults = const [];
                        _searchController.text = r.label;
                      }),
                    ),
                  const SizedBox(height: PlotSpacing.s4),
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
                          onSelected: (_) => setState(() {
                            _shape = s;
                            if (s == 'loop') _end = null;
                          }),
                        ),
                    ],
                  ),
                  if (_shape == 'loop' || _shape == 'out_and_back') ...[
                    const SizedBox(height: PlotSpacing.s3),
                    TextField(
                      controller: _targetKmController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: _shape == 'loop'
                            ? 'Target distance (km) — required'
                            : 'Target distance (km) — or tap a turnaround',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: PlotSpacing.s2),
                      child: Text(
                        _shape == 'loop'
                            ? 'Honoured as an envelope (FR8) — the closest achievable loop, not exact.'
                            : 'The return leg re-solves back to start; it retraces the outbound '
                                'road except where a one-way forces a different way back.',
                        style: PlotTypography.small(c.textMuted),
                      ),
                    ),
                  ],
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
                  Text(_tapHint(), style: PlotTypography.small(c.textSecondary)),
                  const SizedBox(height: PlotSpacing.s2),
                  _PointList(
                    start: _start,
                    end: _shape == 'loop' ? null : _end,
                    via: _via,
                    onClear: () => setState(() {
                      _start = null;
                      _end = null;
                      _via.clear();
                    }),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: PlotSpacing.s3),
                    NoDataBanner(onChooseAnotherArea: () => Navigator.pop(context)),
                  ],
                  const SizedBox(height: PlotSpacing.s5),
                  PlotButton(
                    label: _generating ? 'Generating…' : 'Generate route',
                    expand: true,
                    onPressed: (!_canGenerate || _generating) ? null : _generate,
                  ),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          Expanded(
            child: TapToPickMap(
              points: [?_start, ..._via, if (_shape != 'loop') ?_end],
              onTap: (point) => setState(() => _handleTap(point)),
            ),
          ),
        ],
      ),
    );
  }

  String _tapHint() => switch (_shape) {
        'loop' => 'Tap the map to place start, then up to two via-nodes (A9).',
        'out_and_back' => 'Tap to place start, then optionally a turnaround '
            '(or leave it to the target distance above), then up to two via-nodes.',
        _ => 'Tap the map to place points. First tap sets start, second sets '
            'end; further taps add via-nodes (A9 — 1–2 supported).',
      };

  void _handleTap(List<double> point) {
    if (_start == null) {
      _start = point;
      return;
    }
    if (_shape == 'loop') {
      if (_via.length < 2) _via.add(point);
      return;
    }
    if (_end == null) {
      _end = point;
      return;
    }
    if (_via.length < 2) _via.add(point);
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() => _searching = true);
    try {
      final client = ref.read(routingClientProvider);
      final results = await client.geocode(query);
      setState(() => _searchResults = results);
    } on RoutingException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
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
            end: _shape == 'loop' ? null : _end,
            via: _via,
            mode: _mode,
            shape: _shape,
            theme: _theme,
            targetM: _targetM,
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
          Text('End/turnaround: ${end == null ? '—' : fmt(end!)}', style: PlotTypography.data(c.textPrimary)),
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

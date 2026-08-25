// Wireframe screen "00 New Route" — trip setup (name, dates, party size,
// primary modes, start method) plus mode/shape/theme/start/end/via picked
// before the first solve. `client/design/README.md` flags the pre-2026-08-17
// pass of this wireframe as predating A7 (shape selector beyond "loop") and
// A9 (via-node UI); both were already built here.
//
// The wireframe splits this into two steps (pick a start point, then a
// setup form); this screen keeps them on one screen instead, in labeled
// sections, because start-point-picking and the mode/shape/theme decisions
// were already interleaved here (tapping the map places start/end/via
// depending on which shape is selected) before this pass — forcing a hard
// step wall between "map" and "everything else" would fight that existing
// interaction rather than improve it. Trip name and dates write real schema
// fields (`Trip.title`/`Trip.duration`); party size and primary modes have
// no schema home and live in `state/trip_authoring_meta_provider.dart`
// instead (that file's doc comment explains why).
//
// START FROM has three real, distinct behaviors, not just wireframe copy:
// "Blank canvas" skips generation and drops the Author straight into an
// empty route day (`CurrentTripNotifier.addBlankDay`) to build manually;
// "Generate from a theme" is the pre-existing sidecar-solve flow below;
// "Import a GPX track" is honestly disabled — no GPX parser exists yet,
// same pattern as FIT export's caption rather than a silent gap.
//
// All three solver shapes are live: `/segments/generate` routes to
// `routing/loops.py`'s `generate_loop`/`generate_out_and_back` for the two
// loop-family shapes and `routing/solve.py`'s `generate_segment` for
// point-to-point (MVP doc §8, resolved this session).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/routing_client.dart';
import '../../data/sidecar_manager.dart' show CapabilityStatus;
import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import '../../state/providers.dart';
import '../../state/trip_authoring_meta_provider.dart';
import '../../state/trip_bbox_provider.dart';
import '../map/tap_to_pick_map.dart';
import '../widgets/error_states.dart';

enum _StartMethod { blank, theme, import }

class NewRouteScreen extends ConsumerStatefulWidget {
  const NewRouteScreen({super.key, this.initialCenter});

  /// A10 — where the trip-creation location prompt resolved to, if the
  /// Author entered one. Centers the map only; it is never treated as a
  /// start point or any other kind of extent.
  final List<double>? initialCenter;

  @override
  ConsumerState<NewRouteScreen> createState() => _NewRouteScreenState();
}

class _NewRouteScreenState extends ConsumerState<NewRouteScreen> {
  String _mode = 'cycling';
  // FR7/A7 — the AC-stated default shape (`planner_ui_state.dart`'s single
  // source of truth for it): loop needs only a start, no destination,
  // unlike point_to_point.
  String _shape = defaultSegmentShape;
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

  _StartMethod _startMethod = _StartMethod.theme;
  late final _tripNameController =
      TextEditingController(text: ref.read(currentTripProvider).title);
  final _startDateController = TextEditingController();
  final _endDateController = TextEditingController();

  static const _modes = ['cycling', 'hiking', 'paddling', 'transit'];
  static const _shapes = ['loop', 'out_and_back', 'point_to_point'];
  static const _themes = ['balanced', 'quiet_scenic', 'fastest', 'gravel'];
  // Wireframe screen 00 shows only Ride/Paddle/Hike by default, plus a
  // "+ Add" affordance for anything else — Transit isn't a default chip.
  static const _basePrimaryModes = ['cycling', 'paddling', 'hiking'];
  static const _primaryModeChoices = ['cycling', 'paddling', 'hiking', 'transit'];

  @override
  void dispose() {
    _targetKmController.dispose();
    _searchController.dispose();
    _tripNameController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  double? get _targetM {
    final km = double.tryParse(_targetKmController.text);
    return km == null ? null : km * 1000;
  }

  bool get _canGenerate => canGenerateShape(
        shape: _shape,
        hasStart: _start != null,
        hasEnd: _end != null,
        hasTargetM: _targetM != null,
      );

  /// ARCH §8.3 / PRD FR121 (M12a), FR120/D41 (issue #154) — routing is
  /// per-region now: this reads the capability for the trip's *own* bbox
  /// (`tripRegionKeyProvider`), not a process-wide flag. No trip bbox yet,
  /// or the region still being ensured, both read as an honest not-ready
  /// with a stated reason (FR121: never a silent disabled control).
  CapabilityStatus get _routingCapability {
    final regionAsync = ref.watch(tripRegionKeyProvider);
    return regionAsync.when(
      data: (key) {
        if (key == null) {
          return const CapabilityStatus(
            ready: false,
            reason: 'draw the trip area before routing is available',
          );
        }
        return ref.watch(sidecarManagerProvider).capabilities?.routing.forRegion(key) ??
            const CapabilityStatus(ready: false, reason: 'ensuring the routing region');
      },
      loading: () =>
          const CapabilityStatus(ready: false, reason: 'ensuring the routing region'),
      error: (e, _) => CapabilityStatus(ready: false, reason: 'failed:$e'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New route')),
      body: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                TapToPickMap(
                  points: [?_start, ..._via, if (_shape != 'loop') ?_end],
                  onTap: (point) => setState(() => _handleTap(point)),
                  center: widget.initialCenter,
                ),
                Positioned(
                  left: PlotSpacing.s4,
                  bottom: PlotSpacing.s4,
                  width: 360,
                  child: _LocationSearchBar(
                    controller: _searchController,
                    searching: _searching,
                    results: _searchResults,
                    onSearch: _search,
                    onPick: (r) => setState(() {
                      _start = r.coord;
                      _searchResults = const [];
                      _searchController.text = r.label;
                    }),
                  ),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(PlotSpacing.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionLabel('TRIP NAME'),
                  TextField(
                    controller: _tripNameController,
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                    onSubmitted: (v) => v.trim().isEmpty
                        ? null
                        : ref.read(currentTripProvider.notifier).renameTrip(v.trim()),
                  ),
                  const SizedBox(height: PlotSpacing.s4),
                  _SectionLabel('PRIMARY MODES · pick any'),
                  Builder(builder: (context) {
                    final selected = ref.watch(tripAuthoringMetaProvider).primaryModes;
                    final extra = _primaryModeChoices
                        .where((m) => !_basePrimaryModes.contains(m))
                        .toList();
                    final shownExtra = extra.where(selected.contains);
                    final addable = extra.where((m) => !selected.contains(m)).toList();
                    return Wrap(
                      spacing: PlotSpacing.s2,
                      runSpacing: PlotSpacing.s2,
                      children: [
                        for (final m in _basePrimaryModes)
                          _PlotToggleChip(
                            label: _modeLabel(m),
                            icon: _modeIcon(m),
                            selected: selected.contains(m),
                            onTap: () =>
                                ref.read(tripAuthoringMetaProvider.notifier).togglePrimaryMode(m),
                          ),
                        for (final m in shownExtra)
                          _PlotToggleChip(
                            label: _modeLabel(m),
                            icon: _modeIcon(m),
                            selected: true,
                            onTap: () =>
                                ref.read(tripAuthoringMetaProvider.notifier).togglePrimaryMode(m),
                          ),
                        if (addable.isNotEmpty)
                          PopupMenuButton<String>(
                            tooltip: 'Add a mode',
                            onSelected: (m) =>
                                ref.read(tripAuthoringMetaProvider.notifier).togglePrimaryMode(m),
                            itemBuilder: (context) => [
                              for (final m in addable)
                                PopupMenuItem(value: m, child: Text(_modeLabel(m))),
                            ],
                            child: _PlotToggleChip(
                              label: 'Add',
                              icon: Icons.add,
                              selected: false,
                              onTap: null,
                            ),
                          ),
                      ],
                    );
                  }),
                  const SizedBox(height: PlotSpacing.s4),
                  _SectionLabel('DATES'),
                  InkWell(
                    onTap: _pickDates,
                    borderRadius: PlotRadii.controlShape,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: PlotSpacing.s3, vertical: PlotSpacing.s3),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.border),
                        borderRadius: PlotRadii.controlShape,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.calendar_today_outlined, size: 16, color: c.textSecondary),
                          const SizedBox(width: PlotSpacing.s2),
                          Text(_dateRangeLabel(), style: PlotTypography.body(c.textPrimary)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: PlotSpacing.s4),
                  _SectionLabel('PARTY SIZE'),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s1),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.border),
                      borderRadius: PlotRadii.controlShape,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.people_outline, size: 18, color: c.textSecondary),
                        const SizedBox(width: PlotSpacing.s2),
                        Expanded(
                          child: Builder(builder: (context) {
                            final size = ref.watch(tripAuthoringMetaProvider).partySize ?? 1;
                            return Text('$size ${size == 1 ? 'rider' : 'riders'}',
                                style: PlotTypography.body(c.textPrimary));
                          }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, size: 20),
                          onPressed: () {
                            final size = ref.read(tripAuthoringMetaProvider).partySize ?? 1;
                            ref.read(tripAuthoringMetaProvider.notifier).setPartySize(
                                  size <= 1 ? 1 : size - 1,
                                );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, size: 20),
                          onPressed: () {
                            final size = ref.read(tripAuthoringMetaProvider).partySize ?? 1;
                            ref.read(tripAuthoringMetaProvider.notifier).setPartySize(size + 1);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: PlotSpacing.s5),
                  _SectionLabel('START FROM'),
                  _StartMethodOption(
                    title: 'Blank canvas',
                    detail: 'Place nodes yourself, weight the route as you go',
                    selected: _startMethod == _StartMethod.blank,
                    onTap: () => setState(() => _startMethod = _StartMethod.blank),
                  ),
                  _StartMethodOption(
                    title: 'Generate from a theme',
                    detail: 'Set weights first, let Plotlines draft a route',
                    selected: _startMethod == _StartMethod.theme,
                    onTap: () => setState(() => _startMethod = _StartMethod.theme),
                  ),
                  _StartMethodOption(
                    title: 'Import a GPX track',
                    detail: 'Not built yet — bring an existing route, then layer story on top',
                    selected: _startMethod == _StartMethod.import,
                    disabled: true,
                    onTap: () => setState(() => _startMethod = _StartMethod.import),
                  ),
                  const SizedBox(height: PlotSpacing.s5),
                  if (_startMethod == _StartMethod.theme) ...[
                    _SectionLabel('MODE'),
                    Wrap(
                      spacing: PlotSpacing.s2,
                      runSpacing: PlotSpacing.s2,
                      children: [
                        for (final m in _modes)
                          _PlotToggleChip(
                            label: _modeLabel(m),
                            icon: _modeIcon(m),
                            selected: _mode == m,
                            onTap: () => setState(() => _mode = m),
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
                      runSpacing: PlotSpacing.s2,
                      children: [
                        for (final s in _shapes)
                          _PlotToggleChip(
                            label: s.replaceAll('_', ' '),
                            selected: _shape == s,
                            onTap: () => setState(() {
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
                      runSpacing: PlotSpacing.s2,
                      children: [
                        for (final t in _themes)
                          _PlotToggleChip(
                            label: t.replaceAll('_', ' '),
                            selected: _theme == t,
                            onTap: () => setState(() => _theme = t),
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
                    if (!_routingCapability.ready) ...[
                      const SizedBox(height: PlotSpacing.s3),
                      CapabilityWarmingNotice(capabilityLabel: 'Routing', status: _routingCapability),
                    ],
                    const SizedBox(height: PlotSpacing.s5),
                    PlotButton(
                      label: _generating ? 'Generating…' : 'Generate route',
                      expand: true,
                      onPressed: (!_canGenerate || _generating || !_routingCapability.ready)
                          ? null
                          : _generate,
                    ),
                  ] else if (_startMethod == _StartMethod.blank)
                    PlotButton(
                      label: 'Create route',
                      expand: true,
                      onPressed: _createBlank,
                    ),
                ],
              ),
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

  void _syncDuration() {
    final start = _startDateController.text.trim();
    final end = _endDateController.text.trim();
    ref.read(currentTripProvider.notifier).setDuration(TripDuration(
          startDate: start.isEmpty ? null : start,
          endDate: end.isEmpty ? null : end,
        ));
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final initialStart = DateTime.tryParse(_startDateController.text) ?? now;
    final initialEnd = DateTime.tryParse(_endDateController.text) ??
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
    setState(() {
      _startDateController.text = DateFormat('yyyy-MM-dd').format(range.start);
      _endDateController.text = DateFormat('yyyy-MM-dd').format(range.end);
    });
    _syncDuration();
  }

  // Wireframe screen 00's DATES field shows a formatted range ("Sep 12–15"),
  // not the raw ISO strings the two source fields hold.
  String _dateRangeLabel() {
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (start == null) return 'Set dates';
    if (end == null || DateUtils.isSameDay(start, end)) return DateFormat('MMM d').format(start);
    if (start.month == end.month) {
      return '${DateFormat('MMM d').format(start)}–${DateFormat('d').format(end)}';
    }
    return '${DateFormat('MMM d').format(start)} – ${DateFormat('MMM d').format(end)}';
  }

  static String _modeLabel(String m) => switch (m) {
        'cycling' => 'Ride',
        'paddling' => 'Paddle',
        'hiking' => 'Hike',
        'transit' => 'Transit',
        _ => m,
      };

  static IconData _modeIcon(String m) => switch (m) {
        'hiking' => Icons.hiking,
        'paddling' => Icons.kayaking,
        'transit' => Icons.directions_transit,
        _ => Icons.directions_bike,
      };

  void _createBlank() {
    final title = _tripNameController.text.trim();
    if (title.isNotEmpty) {
      ref.read(currentTripProvider.notifier).renameTrip(title);
    }
    ref.read(currentTripProvider.notifier).addBlankDay();
    context.go('/plan');
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
    // The TRIP NAME field only renames on Enter (`onSubmitted`) — flush it
    // here too so clicking Generate directly doesn't silently discard it.
    final title = _tripNameController.text.trim();
    if (title.isNotEmpty) {
      ref.read(currentTripProvider.notifier).renameTrip(title);
    }
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
      if (mounted) context.go('/plan');
    } on RoutingException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }
}

class _StartMethodOption extends StatelessWidget {
  const _StartMethodOption({
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });
  final String title;
  final String detail;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: PlotRadii.controlShape,
        child: Container(
          padding: const EdgeInsets.all(PlotSpacing.s3),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? c.primary : c.border, width: selected ? 1.5 : 1),
            borderRadius: PlotRadii.controlShape,
            color: disabled ? c.surfaceSunk : null,
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: disabled ? c.textMuted : (selected ? c.primary : c.textSecondary),
              ),
              const SizedBox(width: PlotSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: PlotTypography.body(disabled ? c.textMuted : c.textPrimary)
                            .copyWith(fontWeight: FontWeight.w600)),
                    Text(detail, style: PlotTypography.small(c.textMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

/// The app's established toggle-chip look (see `_SegmentChip` in
/// `day_timeline_strip.dart`) — a bordered box, filled + accent border when
/// selected — used here in place of Material's default `ChoiceChip`/
/// `FilterChip` so mode/shape/theme pickers match the rest of the app
/// instead of the stock Material chip style.
class _PlotToggleChip extends StatelessWidget {
  const _PlotToggleChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: PlotRadii.controlShape,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
        decoration: BoxDecoration(
          color: selected ? c.primary.withValues(alpha: 0.1) : c.surfaceCard,
          border: Border.all(color: selected ? c.primary : c.border, width: selected ? 1.5 : 1),
          borderRadius: PlotRadii.controlShape,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: selected ? c.primary : c.textSecondary),
              const SizedBox(width: PlotSpacing.s2),
            ],
            Text(
              label,
              style: PlotTypography.data(selected ? c.primary : c.textPrimary)
                  .copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wireframe screen 00's start-point search — a search bar floating over the
/// map's bottom-left corner, not a section in the form panel. Results render
/// as a card stacked above the field, in the same floating group.
class _LocationSearchBar extends StatelessWidget {
  const _LocationSearchBar({
    required this.controller,
    required this.searching,
    required this.results,
    required this.onSearch,
    required this.onPick,
  });
  final TextEditingController controller;
  final bool searching;
  final List<GeocodeResult> results;
  final VoidCallback onSearch;
  final ValueChanged<GeocodeResult> onPick;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: PlotSpacing.s2),
            child: PlotCard(
              padding: const EdgeInsets.symmetric(vertical: PlotSpacing.s1),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final r in results) PlotListTile(title: r.label, onTap: () => onPick(r)),
                ],
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3),
          decoration: BoxDecoration(
            color: c.surfaceCard.withValues(alpha: 0.96),
            border: Border.all(color: c.border),
            borderRadius: PlotRadii.controlShape,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8)],
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: c.textSecondary),
              const SizedBox(width: PlotSpacing.s2),
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Search a town, or click the map to drop a start',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onSubmitted: (_) => onSearch(),
                ),
              ),
              if (searching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: PlotSpacing.s2),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                IconButton(
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  onPressed: onSearch,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

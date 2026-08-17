// Wireframe screen "01 Route Planner" — the main authoring canvas: day/segment
// list (Epic C), map, D1's live metrics dashboard, and the entry points into
// segment editing (weights/bands, "02 Constraint Conflict") and node curation
// ("03 Node & Narrative").
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import '../../state/settings_provider.dart';
import '../map/tap_to_pick_map.dart';
import '../widgets/node_editor_sheet.dart';
import '../widgets/segment_editor_sheet.dart';

class RoutePlannerScreen extends ConsumerStatefulWidget {
  const RoutePlannerScreen({super.key});
  @override
  ConsumerState<RoutePlannerScreen> createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends ConsumerState<RoutePlannerScreen> {
  bool _addingNode = false;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final trip = ref.watch(currentTripProvider);
    final selected = ref.watch(selectedSegmentProvider);
    final selectedSegment = _findSelected(trip, selected);
    final unit = ref.watch(settingsProvider).unit;

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => _renameTrip(context, trip.title),
          child: Text(trip.title, style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 20)),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await ref.read(tripPersistenceProvider).save();
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Saved locally')));
              }
            },
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save'),
          ),
          TextButton.icon(
            onPressed: () => context.push('/cues'),
            icon: const Icon(Icons.list_alt_outlined, size: 18),
            label: const Text('Cue sheet + export'),
          ),
          const SizedBox(width: PlotSpacing.s3),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 340,
            child: _DayList(trip: trip, selected: selected),
          ),
          VerticalDivider(width: 1, color: c.border),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      TapToPickMap(
                        points: [
                          for (final d in trip.days)
                            for (final s in d.segments)
                              if (s.start != null) s.start!,
                          for (final d in trip.days)
                            for (final s in d.segments)
                              if (s.end != null) s.end!,
                        ],
                        polyline: selectedSegment?.geometry?.coordinates ?? const [],
                        onTap: (!_addingNode || selected == null)
                            ? null
                            : (point) {
                                showNodeEditorSheet(
                                  context,
                                  dayId: selected.$1,
                                  segmentId: selected.$2,
                                  coord: point,
                                );
                                setState(() => _addingNode = false);
                              },
                      ),
                      if (selected != null)
                        Positioned(
                          top: PlotSpacing.s3,
                          right: PlotSpacing.s3,
                          child: PlotButton(
                            label: _addingNode ? 'Tap map to place node…' : 'Add node',
                            icon: Icons.add_location_alt_outlined,
                            variant: _addingNode ? PlotButtonVariant.secondary : PlotButtonVariant.primary,
                            onPressed: () => setState(() => _addingNode = !_addingNode),
                          ),
                        ),
                    ],
                  ),
                ),
                Divider(height: 1, color: c.border),
                _MetricsDashboard(
                  trip: trip,
                  selectedSegment: selectedSegment,
                  unitLabel: unit == DistanceUnit.km ? 'km' : 'mi',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Segment? _findSelected(Trip trip, (String, String)? selected) {
    if (selected == null) return null;
    for (final d in trip.days) {
      if (d.id != selected.$1) continue;
      for (final s in d.segments) {
        if (s.id == selected.$2) return s;
      }
    }
    return null;
  }

  Future<void> _renameTrip(BuildContext context, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename trip'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      ref.read(currentTripProvider.notifier).renameTrip(result.trim());
    }
  }
}

class _DayList extends ConsumerWidget {
  const _DayList({required this.trip, required this.selected});
  final Trip trip;
  final (String, String)? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(PlotSpacing.s4),
            children: [
              for (final day in trip.days) _DayCard(day: day, selected: selected),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(PlotSpacing.s4),
          child: Row(
            children: [
              Expanded(
                child: PlotButton(
                  label: 'New route day',
                  variant: PlotButtonVariant.secondary,
                  icon: Icons.add,
                  onPressed: () {
                    ref.read(plannerTargetDayIdProvider.notifier).state = null;
                    context.push('/new');
                  },
                ),
              ),
              const SizedBox(width: PlotSpacing.s2),
              // C2 — a rest day is a day with no segments, created directly
              // here since it never needs the New Route flow.
              IconButton(
                tooltip: 'Add rest day',
                icon: Icon(Icons.hotel_outlined, color: c.textSecondary),
                onPressed: () => ref.read(currentTripProvider.notifier).setDayKind(
                      // A fresh id: `setDayKind` creates the day when none matches.
                      DateTime.now().microsecondsSinceEpoch.toString(),
                      'rest',
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DayCard extends ConsumerWidget {
  const _DayCard({required this.day, required this.selected});
  final Day day;
  final (String, String)? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PlotSpacing.s3),
      child: PlotCard(
        padding: const EdgeInsets.all(PlotSpacing.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Day ${day.index}', style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: PlotSpacing.s2),
                if (day.roles.contains('start')) const PlotBadge('Start', tone: PlotBadgeTone.spruce),
                if (day.roles.contains('end')) const PlotBadge('End', tone: PlotBadgeTone.spruce),
                if (day.isRest) const PlotBadge('Rest', tone: PlotBadgeTone.slate),
                const Spacer(),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, size: 18, color: c.textMuted),
                  onSelected: (action) {
                    final notifier = ref.read(currentTripProvider.notifier);
                    switch (action) {
                      case 'start':
                        notifier.toggleDayRole(day.id, 'start');
                      case 'end':
                        notifier.toggleDayRole(day.id, 'end');
                      case 'rest':
                        notifier.setDayKind(day.id, day.isRest ? 'route' : 'rest');
                      case 'remove':
                        notifier.removeDay(day.id);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'start', child: Text('Toggle Start')),
                    PopupMenuItem(value: 'end', child: Text('Toggle End')),
                    PopupMenuItem(value: 'rest', child: Text('Toggle Rest day')),
                    PopupMenuItem(value: 'remove', child: Text('Remove day')),
                  ],
                ),
              ],
            ),
            for (final segment in day.segments)
              _SegmentTile(
                day: day,
                segment: segment,
                selected: selected?.$2 == segment.id,
              ),
            if (!day.isRest)
              Align(
                alignment: Alignment.centerLeft,
                child: PlotButton(
                  label: 'Add segment',
                  variant: PlotButtonVariant.ghost,
                  icon: Icons.add,
                  onPressed: () {
                    ref.read(plannerTargetDayIdProvider.notifier).state = day.id;
                    context.push('/new');
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SegmentTile extends ConsumerWidget {
  const _SegmentTile({required this.day, required this.segment, required this.selected});
  final Day day;
  final Segment segment;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    final km = segment.metrics?.distanceM == null ? null : segment.metrics!.distanceM! / 1000;
    final stale = segment.solve?.stale ?? false;
    return PlotListTile(
      onTap: () {
        ref.read(selectedSegmentProvider.notifier).state = (day.id, segment.id);
        showSegmentEditorSheet(context, dayId: day.id, segment: segment);
      },
      leading: Icon(
        switch (segment.mode) {
          'hiking' => Icons.hiking,
          'paddling' => Icons.kayaking,
          'transit' => Icons.directions_transit,
          _ => Icons.directions_bike,
        },
        color: selected ? c.primary : c.textSecondary,
      ),
      title: '${segment.mode} · ${segment.shape.replaceAll('_', ' ')}',
      subtitle: segment.nodes.isEmpty ? null : '${segment.nodes.length} node(s)',
      trailingMono: km == null ? '—' : '${km.toStringAsFixed(1)} km',
      trailing: stale
          ? Icon(Icons.sync_problem, size: 16, color: c.warning)
          : null,
    );
  }
}

class _MetricsDashboard extends StatelessWidget {
  const _MetricsDashboard({required this.trip, required this.selectedSegment, required this.unitLabel});
  final Trip trip;
  final Segment? selectedSegment;
  final String unitLabel;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    double distance = 0, climb = 0;
    for (final d in trip.days) {
      for (final s in d.segments) {
        distance += s.metrics?.distanceM ?? 0;
        climb += s.metrics?.climbM ?? s.elevation?.ascentM ?? 0;
      }
    }
    final km = distance / 1000;
    final displayDistance = unitLabel == 'mi' ? km * 0.621371 : km;
    final samples = selectedSegment?.elevation?.samples ?? const <double>[];
    final normalized = _normalize(samples);

    return Container(
      color: c.surfaceCard,
      padding: const EdgeInsets.all(PlotSpacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('TRIP TOTAL', style: PlotTypography.data(c.textMuted).copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('${displayDistance.toStringAsFixed(1)} $unitLabel', style: PlotTypography.data(c.textPrimary).copyWith(fontSize: 16)),
              Text('↑ ${climb.toStringAsFixed(0)} m', style: PlotTypography.data(c.textSecondary)),
            ],
          ),
          const SizedBox(width: PlotSpacing.s6),
          if (normalized.isNotEmpty)
            Expanded(
              child: ElevationProfile(
                samples: normalized,
                height: 80,
                startLabel: '0',
                endLabel: selectedSegment?.metrics?.distanceM == null
                    ? null
                    : '${(selectedSegment!.metrics!.distanceM! / 1000).toStringAsFixed(1)} km',
              ),
            )
          else
            Expanded(
              child: Center(
                child: Text('Select a segment to see its elevation profile',
                    style: PlotTypography.small(c.textMuted)),
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

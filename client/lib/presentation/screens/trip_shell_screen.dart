// The Trip Shell — wireframe screens "01 Route Planner" / "02 Constraint
// Conflict" / "03 Node & Narrative" / "04 Cue Sheet + Export" are one
// persistent window in the wireframe (`Route / Logistics / Content /
// Export` tabs, weights + metrics rails that stay mounted across tab
// switches) rather than four separate screens — this is that shell,
// replacing the GoRouter-pushed `route_planner_screen.dart` and
// `cue_sheet_screen.dart` (both deleted; their content lives in
// `plan_tabs/route_tab.dart` and `plan_tabs/export_tab.dart`).
// `selectedSegmentProvider` (`state/planner_ui_state.dart`) is the shared
// seam Route and Content both work against.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import 'plan_tabs/content_tab.dart';
import 'plan_tabs/export_tab.dart';
import 'plan_tabs/layers_tab.dart';
import 'plan_tabs/logistics_tab.dart';
import 'plan_tabs/roster_tab.dart';
import 'plan_tabs/route_tab.dart';

class TripShellScreen extends ConsumerStatefulWidget {
  const TripShellScreen({super.key});

  @override
  ConsumerState<TripShellScreen> createState() => _TripShellScreenState();
}

class _TripShellScreenState extends ConsumerState<TripShellScreen> with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 6, vsync: this)..addListener(_handleTabChange);
  String? _activeDayId;
  int _activeTabIndex = 0;

  /// The trip whose sync-alert interrupt has already been raised this session,
  /// so opening the shell doesn't re-interrupt on every rebuild (C11 / FR27 /
  /// issue #210).
  String? _syncAlertsRaisedForTripId;

  void _handleTabChange() {
    if (_tabController.index != _activeTabIndex) {
      setState(() => _activeTabIndex = _tabController.index);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _syncActiveDay(Trip trip) {
    if (trip.days.isEmpty) {
      _activeDayId = null;
      return;
    }
    if (_activeDayId == null || !trip.days.any((d) => d.id == _activeDayId)) {
      _activeDayId = trip.days.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final trip = ref.watch(currentTripProvider);
    _syncActiveDay(trip);
    _maybeRaiseSyncAlerts(trip);

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => _renameTrip(context, trip.title),
          child: Text(trip.title, style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 20)),
        ),
        actions: [
          // N1 (FR120) — "revisable throughout authoring," and FR142(b)'s
          // reachability rule: the bbox needs a named path back to it, not
          // just the one at trip creation.
          IconButton(
            tooltip: 'Trip area',
            onPressed: () => context.push('/trip-area'),
            icon: const Icon(Icons.crop_free, size: 18),
          ),
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
          const SizedBox(width: PlotSpacing.s3),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'ROUTE'),
            Tab(text: 'LOGISTICS'),
            Tab(text: 'LAYERS'),
            Tab(text: 'CONTENT'),
            Tab(text: 'ROSTER'),
            Tab(text: 'EXPORT'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _LazyTab(
            active: _activeTabIndex == 0,
            builder: (_) => RouteTab(
              trip: trip,
              activeDayId: _activeDayId,
              onSelectDay: (id) => setState(() => _activeDayId = id),
            ),
          ),
          _LazyTab(
            active: _activeTabIndex == 1,
            builder: (_) => LogisticsTab(
              trip: trip,
              onOpenSegment: (dayId, segmentId) {
                ref.read(selectedSegmentProvider.notifier).state = (dayId, segmentId);
                setState(() => _activeDayId = dayId);
                _tabController.animateTo(0);
              },
            ),
          ),
          _LazyTab(
            active: _activeTabIndex == 2,
            builder: (_) => LayersTab(trip: trip, activeDayId: _activeDayId),
          ),
          _LazyTab(active: _activeTabIndex == 3, builder: (_) => ContentTab(trip: trip)),
          _LazyTab(active: _activeTabIndex == 4, builder: (_) => const RosterTab()),
          _LazyTab(active: _activeTabIndex == 5, builder: (_) => ExportTab(trip: trip)),
        ],
      ),
    );
  }

  /// C11 / FR27 (issue #210) — the trip-open interrupt: the worst-first set of
  /// high-severity hazards a Character should see *before* they are standing on
  /// one. Raised once per trip per session; a trip with only `caution` hazards
  /// (or none) never interrupts. `HazardRollup.fromTrip` is the client mirror of
  /// `plotlines_core.trips.hazards` — the same one traversal every hazard
  /// surface reads.
  void _maybeRaiseSyncAlerts(Trip trip) {
    if (_syncAlertsRaisedForTripId == trip.id) return;
    final rollup = HazardRollup.fromTrip(trip);
    if (!rollup.hasSyncAlerts) return;
    _syncAlertsRaisedForTripId = trip.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => _SyncAlertsDialog(rollup: rollup),
      );
    });
  }

  Future<void> _renameTrip(BuildContext context, String current) async {
    final controller = TextEditingController(text: current);
    try {
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
    } finally {
      controller.dispose();
    }
  }
}

/// A [TabBarView] child that only builds its real content while [active] —
/// every other tab's trip-derived data (weights rail, map, cue-sheet
/// scaffolding, …) would otherwise get reconstructed on every trip
/// mutation regardless of which tab is actually visible, since all four
/// children are built from one shell-level `ref.watch(currentTripProvider)`
/// (see the class doc comment on why one shared watch, not four). The
/// trade-off, accepted deliberately: a hidden tab's own local state (e.g.
/// Content's selected-node chip) resets when you switch away and back,
/// since its widget subtree is torn down rather than kept alive off-screen —
/// a real cost, but a rare interaction next to the frame-by-frame rebuild
/// this avoids on the common one (dragging a weight slider).
class _LazyTab extends StatelessWidget {
  const _LazyTab({required this.active, required this.builder});
  final bool active;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => active ? builder(context) : const SizedBox.shrink();
}

/// C11 / FR27 (issue #210) — the sync-open interrupt. Lists the worst-first
/// [SyncAlert] set as structured fields (severity, where it sits, the Author's
/// safety note, required gear), never as a composed sentence. Hazards are never
/// reveal-gated (FR115), so nothing here is filtered.
class _SyncAlertsDialog extends StatelessWidget {
  const _SyncAlertsDialog({required this.rollup});

  final HazardRollup rollup;

  static const _severityLabel = {
    'mandatory_reroute': 'MANDATORY RE-ROUTE',
    'high': 'HIGH',
  };

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final alerts = rollup.syncAlerts;
    final lowerCount = rollup.hazards.length - alerts.length;

    return AlertDialog(
      title: Text('Hazards on this trip', style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 20)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${alerts.length} need${alerts.length == 1 ? 's' : ''} your attention before you set out.',
                style: PlotTypography.body(c.textSecondary),
              ),
              const SizedBox(height: PlotSpacing.s3),
              for (final a in alerts) ...[
                _AlertRow(alert: a),
                const SizedBox(height: PlotSpacing.s3),
              ],
              if (lowerCount > 0)
                Text(
                  '$lowerCount more lower-severity hazard${lowerCount == 1 ? '' : 's'} '
                  'on the route — see the cue sheet.',
                  style: PlotTypography.small(c.textSecondary),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Got it')),
      ],
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.alert});

  final SyncAlert alert;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final place = [
      'Day ${alert.dayIndex}',
      if (alert.anchorTitle != null) alert.anchorTitle!,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _SyncAlertsDialog._severityLabel[alert.severity] ?? alert.severity.toUpperCase(),
              style: PlotTypography.small(c.danger).copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: PlotSpacing.s2),
            Text(place, style: PlotTypography.small(c.textSecondary)),
          ],
        ),
        if (alert.title != null)
          Text(alert.title!, style: PlotTypography.body(c.textPrimary).copyWith(fontWeight: FontWeight.w600)),
        if (alert.safetyNote != null)
          Text(alert.safetyNote!, style: PlotTypography.body(c.textSecondary)),
        if (alert.requiredGear.isNotEmpty)
          Text('Required: ${alert.requiredGear.join(', ')}',
              style: PlotTypography.small(c.textSecondary)),
      ],
    );
  }
}

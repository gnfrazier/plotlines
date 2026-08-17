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
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/domain.dart';
import '../../state/current_trip_provider.dart';
import '../../state/planner_ui_state.dart';
import 'plan_tabs/content_tab.dart';
import 'plan_tabs/export_tab.dart';
import 'plan_tabs/logistics_tab.dart';
import 'plan_tabs/route_tab.dart';

class TripShellScreen extends ConsumerStatefulWidget {
  const TripShellScreen({super.key});

  @override
  ConsumerState<TripShellScreen> createState() => _TripShellScreenState();
}

class _TripShellScreenState extends ConsumerState<TripShellScreen> with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 4, vsync: this);
  String? _activeDayId;

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
          const SizedBox(width: PlotSpacing.s3),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'ROUTE'),
            Tab(text: 'LOGISTICS'),
            Tab(text: 'CONTENT'),
            Tab(text: 'EXPORT'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          RouteTab(
            trip: trip,
            activeDayId: _activeDayId,
            onSelectDay: (id) => setState(() => _activeDayId = id),
          ),
          LogisticsTab(
            trip: trip,
            onOpenSegment: (dayId, segmentId) {
              ref.read(selectedSegmentProvider.notifier).state = (dayId, segmentId);
              setState(() => _activeDayId = dayId);
              _tabController.animateTo(0);
            },
          ),
          ContentTab(trip: trip),
          ExportTab(trip: trip),
        ],
      ),
    );
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

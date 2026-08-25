// Wireframe screen "05 Open Trip" (G2a, PRD FR74a) — save a trip locally,
// reopen it, list what exists. The "plain thing", deliberately lighter than
// G2's [P1] portfolio surface: no sync badges, no roster, no thumbnails
// beyond the brand hatch pattern. Adds the wireframe's search field and
// grid/list toggle over the previous grid-only pass; "About" moved into
// the merged Preferences & About screen (settings_screen.dart) per the
// wireframe's screen 06, so this app bar only routes to Settings now.
//
// Also owns A10's cold-start map (PRD FR96, Author Flows MVP §Flow 1): with
// no trips yet, this screen shows the shipped Buncombe County home region
// rather than a blank/iconic placeholder — a constant, never fetched — and
// "New trip" prompts for a location every time (prefilled with the
// last-used value), never gated behind a one-time first-run dialog.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/app_database.dart';
import '../../domain/home_region.dart';
import '../../state/current_trip_provider.dart';
import '../../state/providers.dart';
import '../../state/trip_authoring_meta_provider.dart';
import '../../state/trip_bbox_provider.dart';
import '../../state/trip_library_provider.dart';
import '../map/tap_to_pick_map.dart';
import '../widgets/trip_location_prompt.dart';

const String _lastTripLocationKey = 'last_trip_location';

class TripLibraryScreen extends ConsumerStatefulWidget {
  const TripLibraryScreen({super.key});

  @override
  ConsumerState<TripLibraryScreen> createState() => _TripLibraryScreenState();
}

class _TripLibraryScreenState extends ConsumerState<TripLibraryScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  bool _grid = true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final tripsAsync = ref.watch(tripLibraryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Plotlines', style: PlotTypography.h2(c.textPrimary).copyWith(fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Preferences & about',
            onPressed: () => context.push('/settings'),
          ),
          const SizedBox(width: PlotSpacing.s2),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startNewTrip(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New trip'),
      ),
      body: tripsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Text('Couldn\'t open the local trip library: $err',
              style: PlotTypography.body(c.danger)),
        ),
        data: (trips) => trips.isEmpty
            ? const _EmptyLibrary()
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        PlotSpacing.s5, PlotSpacing.s4, PlotSpacing.s5, PlotSpacing.s2),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            decoration: const InputDecoration(
                              hintText: 'Search trips',
                              prefixIcon: Icon(Icons.search, size: 18),
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                          ),
                        ),
                        const SizedBox(width: PlotSpacing.s3),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, icon: Icon(Icons.grid_view, size: 16), label: Text('GRID')),
                            ButtonSegment(value: false, icon: Icon(Icons.view_list, size: 16), label: Text('LIST')),
                          ],
                          selected: {_grid},
                          onSelectionChanged: (s) => setState(() => _grid = s.first),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _TripCollection(
                      trips: _query.isEmpty
                          ? trips
                          : trips.where((t) => t.title.toLowerCase().contains(_query)).toList(),
                      grid: _grid,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// A10 — prompts for a location every time a trip starts, prefilled with
  /// whatever was entered last time. Never gates trip creation on having
  /// asked before, and never triggers a download: the chosen location only
  /// centers the map the Author lands on next.
  Future<void> _startNewTrip(BuildContext context, WidgetRef ref) async {
    final db = ref.read(appDatabaseProvider);
    final lastUsed = await db.getSetting(_lastTripLocationKey);
    if (!context.mounted) return;
    final choice = await showTripLocationPrompt(
      context,
      prefill: lastUsed ?? '',
      geocode: ref.read(routingClientProvider).geocode,
    );
    if (choice == null) return; // Author cancelled trip creation entirely.
    await db.setSetting(_lastTripLocationKey, choice.label);
    if (!context.mounted) return;
    ref.read(currentTripProvider.notifier).reset();
    ref.read(tripAuthoringMetaProvider.notifier).reset();
    // N1 (FR120) — the location only centers the map; the Author still has
    // to draw the trip's own bbox before New Route's setup form.
    ref.read(tripBboxProvider.notifier).reset();
    context.push('/new-trip-area', extra: choice);
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PlotSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: PlotRadii.controlShape,
              child: SizedBox(
                width: 420,
                height: 260,
                child: TapToPickMap(
                  center: HomeRegion.center,
                  initialZoom: HomeRegion.previewZoom,
                  outline: HomeRegion.outline,
                ),
              ),
            ),
            const SizedBox(height: PlotSpacing.s4),
            Text('No trips yet', style: PlotTypography.title(c.textPrimary)),
            const SizedBox(height: PlotSpacing.s2),
            Text(
              '${HomeRegion.label} ships with the app so the map is never '
              'blank — start a new trip to draw its own area.',
              textAlign: TextAlign.center,
              style: PlotTypography.body(c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripCollection extends ConsumerWidget {
  const _TripCollection({required this.trips, required this.grid});
  final List<TripListEntry> trips;
  final bool grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (trips.isEmpty) {
      return Center(
        child: Text('No trips match that search.',
            style: PlotTypography.body(PlotColors.of(context).textMuted)),
      );
    }
    if (grid) {
      return GridView.builder(
        padding: const EdgeInsets.all(PlotSpacing.s5),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 320,
          mainAxisSpacing: PlotSpacing.s4,
          crossAxisSpacing: PlotSpacing.s4,
          childAspectRatio: 1.35,
        ),
        itemCount: trips.length,
        itemBuilder: (context, i) => _TripCard(trip: trips[i]),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      itemCount: trips.length,
      separatorBuilder: (_, _) => const SizedBox(height: PlotSpacing.s3),
      itemBuilder: (context, i) => SizedBox(height: 96, child: _TripCard(trip: trips[i])),
    );
  }
}

class _TripCard extends ConsumerWidget {
  const _TripCard({required this.trip});
  final TripListEntry trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onLongPress: () => _confirmDelete(context, ref, trip),
      child: TripCard(
        title: trip.title,
        stats: ['Updated ${_relativeDay(trip.updatedAt)}'],
        modeTag: trip.modes.isEmpty ? null : trip.modes.join('+').toUpperCase(),
        offlineReady: true,
        onTap: () async {
          await ref.read(tripPersistenceProvider).open(trip.id);
          if (context.mounted) context.push('/plan');
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, TripListEntry trip) async {
    final confirmed = await PlotDialog.confirm(
      context,
      title: 'Delete "${trip.title}"?',
      message: 'This removes it from local storage. This can\'t be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed == true) {
      await ref.read(tripPersistenceProvider).delete(trip.id);
    }
  }

  String _relativeDay(DateTime dt) {
    final days = DateTime.now().difference(dt).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    return '$days days ago';
  }
}

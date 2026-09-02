// The Author's Trip Library / portfolio workspace (G2a → G2, PRD FR74 /
// FR74b / FR74a / FR76).
//
// G2a shipped the floor: save a trip locally, reopen it, list what exists,
// with a search field and a grid/list toggle. G2 (#71) builds the portfolio
// surface on top: cards carry distance / elevation / day count / variant
// count / group size and a sync-status badge (FR76); the collection filters
// by mode and by duration; and every card has an actions menu — Edit route,
// Manage roster & preferences, Export backup, Clone. G2b (#73) is the Clone
// action's scope picker (`clone_scope_dialog.dart`) and the four copy scopes
// behind it (`domain/clone.dart`).
//
// Named travel circles (FR143) are Later and not built here.
//
// Also owns A10's cold-start map (PRD FR96, Author Flows MVP §Flow 1): with
// no trips yet, this screen shows the shipped Buncombe County home region
// rather than a blank/iconic placeholder, and "New trip" prompts for a
// location every time (prefilled with the last-used value), never gated
// behind a one-time first-run dialog.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../data/app_database.dart';
import '../../domain/domain.dart';
import '../../domain/home_region.dart';
import '../../state/current_roster_provider.dart';
import '../../state/current_trip_provider.dart';
import '../../state/providers.dart';
import '../../state/trip_authoring_meta_provider.dart';
import '../../state/trip_bbox_provider.dart';
import '../../state/trip_library_provider.dart';
import '../map/tap_to_pick_map.dart';
import '../widgets/clone_scope_dialog.dart';
import '../widgets/trip_location_prompt.dart';
import '../widgets/trip_mode_prompt.dart';

const String _lastTripLocationKey = 'last_trip_location';

/// FR74 — "filter by ... duration". Bucketed off the authored day count so a
/// card with no solved route still filters on the shape of the trip.
enum DurationFilter {
  any('All lengths', null, null),
  dayTrip('Day trip', 1, 1),
  multiDay('Multi-day', 2, 6),
  multiWeek('Multi-week', 7, null);

  const DurationFilter(this.label, this.minDays, this.maxDays);
  final String label;
  final int? minDays;
  final int? maxDays;

  bool matches(int? dayCount) {
    if (this == DurationFilter.any) return true;
    if (dayCount == null || dayCount == 0) return false;
    if (minDays != null && dayCount < minDays!) return false;
    if (maxDays != null && dayCount > maxDays!) return false;
    return true;
  }
}

class TripLibraryScreen extends ConsumerStatefulWidget {
  const TripLibraryScreen({super.key});

  @override
  ConsumerState<TripLibraryScreen> createState() => _TripLibraryScreenState();
}

class _TripLibraryScreenState extends ConsumerState<TripLibraryScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  bool _grid = true;
  final Set<String> _modeFilter = {};
  DurationFilter _durationFilter = DurationFilter.any;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The search + mode + duration filters, applied together (FR74).
  List<TripListEntry> _visible(List<TripListEntry> all) {
    return all.where((t) {
      if (_query.isNotEmpty && !t.title.toLowerCase().contains(_query)) {
        return false;
      }
      if (_modeFilter.isNotEmpty && !t.allModes.any(_modeFilter.contains)) {
        return false;
      }
      if (!_durationFilter.matches(t.summary.dayCount)) return false;
      return true;
    }).toList();
  }

  List<String> _allModes(List<TripListEntry> trips) {
    final modes = <String>{for (final t in trips) ...t.allModes};
    return modes.toList()..sort();
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
      // Issue #230 B2 — the empty state carries the action itself (Flow 1
      // §01 puts the trip-starting actions inline in the empty library), so
      // the FAB would be a second control with the same label on the same
      // screen. It comes back the moment there is a library to sit over.
      floatingActionButton: tripsAsync.maybeWhen(
        data: (trips) => trips.isEmpty,
        orElse: () => false,
      )
          ? null
          : FloatingActionButton.extended(
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
            ? _EmptyLibrary(
                onNewTrip: () => _startNewTrip(context, ref),
              )
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
                  _FilterBar(
                    modes: _allModes(trips),
                    selectedModes: _modeFilter,
                    onToggleMode: (m) => setState(() {
                      _modeFilter.contains(m) ? _modeFilter.remove(m) : _modeFilter.add(m);
                    }),
                    duration: _durationFilter,
                    onDuration: (d) => setState(() => _durationFilter = d),
                  ),
                  Expanded(
                    child: _TripCollection(trips: _visible(trips), grid: _grid),
                  ),
                ],
              ),
      ),
    );
  }

  /// FR144/N0 — declares travel modes first (Flow 1's ordering: mode
  /// declaration ahead of the location prompt), then A10's location prompt
  /// every time a trip starts, prefilled with whatever was entered last
  /// time. Neither step gates trip creation on having been asked before,
  /// and the location choice never triggers a download: it only centers the
  /// map the Author lands on next.
  Future<void> _startNewTrip(BuildContext context, WidgetRef ref) async {
    final modes = await showTripModePrompt(context);
    if (modes == null) return; // Author cancelled trip creation entirely.
    if (!context.mounted) return;
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
    ref.read(currentTripProvider.notifier).setDeclaredModes(modes);
    ref.read(currentRosterProvider.notifier).reset();
    ref.read(tripAuthoringMetaProvider.notifier).reset();
    // N1 (FR120) — the location only centers the map; the Author still has
    // to draw the trip's own bbox before New Route's setup form.
    ref.read(tripBboxProvider.notifier).reset();
    context.push('/new-trip-area', extra: choice);
  }
}

/// FR74 — filter by mode and by duration. Modes are the union of realised and
/// declared modes across the library; the row is hidden entirely when there
/// is nothing to filter on.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.modes,
    required this.selectedModes,
    required this.onToggleMode,
    required this.duration,
    required this.onDuration,
  });

  final List<String> modes;
  final Set<String> selectedModes;
  final ValueChanged<String> onToggleMode;
  final DurationFilter duration;
  final ValueChanged<DurationFilter> onDuration;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s5),
        children: [
          for (final d in DurationFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: PlotSpacing.s2),
              child: ChoiceChip(
                label: Text(d.label, style: PlotTypography.small(c.textSecondary)),
                selected: duration == d,
                onSelected: (_) => onDuration(d),
              ),
            ),
          if (modes.isNotEmpty) ...[
            const SizedBox(width: PlotSpacing.s3),
            for (final m in modes)
              Padding(
                padding: const EdgeInsets.only(right: PlotSpacing.s2),
                child: FilterChip(
                  label: Text(m.toUpperCase(), style: PlotTypography.small(c.textSecondary)),
                  selected: selectedModes.contains(m),
                  onSelected: (_) => onToggleMode(m),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// FR142(c) / K12 and Flow 8 §04 (issue #230 B2) — an empty view names the
/// next action rather than explaining the implementation.
///
/// The shipped copy ("Buncombe County, NC ships with the app so the map is
/// never blank — start a new trip to draw its own area") described why the
/// map behind it is not empty, which is a fact about how Plotlines is built,
/// not a thing to do. Flow 1 §01's own empty library states the absence, says
/// what planning costs (nothing — no account, no network), and offers the
/// action. `New trip` is the one path that exists from here; cloning is
/// offered per card in a populated library and has nothing to clone yet.
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onNewTrip});

  final VoidCallback onNewTrip;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      // The empty state now carries an action and a caption as well as the
      // map, so it has to survive a short window (and a raised text scale —
      // issue #230 A2) rather than assuming 260 px of map always fits.
      final mapHeight = (constraints.maxHeight * 0.42).clamp(120.0, 260.0);
      final mapWidth = (constraints.maxWidth - 64).clamp(200.0, 420.0);
      return SingleChildScrollView(
      child: Center(
      child: Padding(
        padding: const EdgeInsets.all(PlotSpacing.s6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: PlotRadii.controlShape,
                child: SizedBox(
                  width: mapWidth,
                  height: mapHeight,
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
                'Start a new trip and draw the area it covers. Planning works with '
                'no account and no network — signing in only adds sync.',
                textAlign: TextAlign.center,
                style: PlotTypography.body(c.textSecondary),
              ),
              const SizedBox(height: PlotSpacing.s4),
              PlotButton(label: 'New trip', icon: Icons.add, onPressed: onNewTrip),
              const SizedBox(height: PlotSpacing.s4),
              // The home region is a caption on the map it explains, not the
              // headline of the empty state.
              Text(
                '${HomeRegion.label} ships with the app, so the map is never blank.',
                textAlign: TextAlign.center,
                style: PlotTypography.small(c.textMuted),
              ),
            ],
          ),
        ),
      ),
      ),
      );
    });
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
        child: Text('No trips match those filters.',
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
          // Fixed height rather than an aspect ratio: the card face now
          // carries the FR74 metric chips, which wrap to a few lines.
          mainAxisExtent: 244,
        ),
        itemCount: trips.length,
        itemBuilder: (context, i) => _TripCard(trip: trips[i]),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(PlotSpacing.s5),
      itemCount: trips.length,
      separatorBuilder: (_, _) => const SizedBox(height: PlotSpacing.s3),
      // The card needs a bounded height for its Flexible content area.
      itemBuilder: (context, i) => SizedBox(height: 180, child: _TripCard(trip: trips[i])),
    );
  }
}

/// FR74's per-card actions, plus G2a's delete (kept from the long-press it
/// used to live behind).
enum _CardAction { editRoute, manageRoster, exportBackup, clone, delete }

class _TripCard extends ConsumerWidget {
  const _TripCard({required this.trip});
  final TripListEntry trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = PlotColors.of(context);
    return TripCard(
      title: trip.title,
      stats: _stats(),
      modeTag: trip.modes.isEmpty ? null : trip.modes.join('+').toUpperCase(),
      badge: PlotBadge(trip.syncBadge.label, tone: PlotBadgeTone.spruce, solid: true),
      trailing: Material(
        color: c.surfaceCard,
        shape: const CircleBorder(),
        child: PopupMenuButton<_CardAction>(
          icon: Icon(Icons.more_vert, size: 18, color: c.textSecondary),
          tooltip: 'Trip actions',
          onSelected: (a) => _onAction(context, ref, a),
          itemBuilder: (_) => const [
            PopupMenuItem(value: _CardAction.editRoute, child: Text('Edit route')),
            PopupMenuItem(
                value: _CardAction.manageRoster, child: Text('Manage roster & preferences')),
            PopupMenuItem(value: _CardAction.exportBackup, child: Text('Export backup')),
            PopupMenuItem(value: _CardAction.clone, child: Text('Clone…')),
            PopupMenuDivider(),
            PopupMenuItem(value: _CardAction.delete, child: Text('Delete…')),
          ],
        ),
      ),
      onTap: () => _open(context, ref),
    );
  }

  /// FR74's card face: distance / elevation / day count / variant count /
  /// group size, from the denormalized summary (no payload decode). Grouped
  /// into at most three short mono chips so the card stays legible — the
  /// brand `TripCard` is built for a couple of stats, not a table.
  List<String> _stats() {
    final s = trip.summary;
    final out = <String>['Updated ${_relativeDay(trip.updatedAt)}'];

    final route = <String>[
      if (s.distanceM != null) '${(s.distanceM! / 1000).toStringAsFixed(0)} KM',
      if (s.ascentM != null) '↑ ${s.ascentM!.toStringAsFixed(0)} M',
    ];
    if (route.isNotEmpty) out.add(route.join('  '));

    final party = <String>[
      if ((s.dayCount ?? 0) > 0) '${s.dayCount} ${s.dayCount == 1 ? 'DAY' : 'DAYS'}',
      if ((s.variantCount ?? 0) > 0) '${s.variantCount} VAR',
      if ((s.groupSize ?? 0) > 0) '${s.groupSize} IN GROUP',
    ];
    if (party.isNotEmpty) out.add(party.join('  '));

    return out;
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    await ref.read(tripPersistenceProvider).open(trip.id);
    if (context.mounted) context.push('/plan');
  }

  Future<void> _onAction(BuildContext context, WidgetRef ref, _CardAction action) async {
    switch (action) {
      // Edit route / Manage roster / Export backup all land in the trip
      // shell today; deep-linking to a specific tab is a later refinement.
      case _CardAction.editRoute:
      case _CardAction.manageRoster:
      case _CardAction.exportBackup:
        await _open(context, ref);
      case _CardAction.clone:
        await _clone(context, ref);
      case _CardAction.delete:
        await _confirmDelete(context, ref);
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
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

  Future<void> _clone(BuildContext context, WidgetRef ref) async {
    final request = await showCloneScopeDialog(context, tripTitle: trip.title);
    if (request == null || !context.mounted) return;
    final outcome = await ref.read(tripPersistenceProvider).clone(
          trip.id,
          request.scope,
          parts: request.parts,
        );
    if (!context.mounted) return;
    if (outcome.runsTripInitiation) {
      // FR74b — a roster-only clone has no bbox / modes / itinerary to
      // inherit, so it runs trip initiation like a new trip, keeping the
      // roster it just cloned.
      await _initClonedTrip(context, ref, outcome);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cloned as "${outcome.trip.title}"')),
      );
    }
  }

  Future<void> _initClonedTrip(
      BuildContext context, WidgetRef ref, CloneOutcome outcome) async {
    ref.read(tripPersistenceProvider).adopt(outcome);
    final modes = await showTripModePrompt(context);
    if (modes == null || !context.mounted) return;
    final db = ref.read(appDatabaseProvider);
    final lastUsed = await db.getSetting(_lastTripLocationKey);
    if (!context.mounted) return;
    final choice = await showTripLocationPrompt(
      context,
      prefill: lastUsed ?? '',
      geocode: ref.read(routingClientProvider).geocode,
    );
    if (choice == null) return;
    await db.setSetting(_lastTripLocationKey, choice.label);
    if (!context.mounted) return;
    ref.read(currentTripProvider.notifier).setDeclaredModes(modes);
    ref.read(tripBboxProvider.notifier).reset();
    context.push('/new-trip-area', extra: choice);
  }

  String _relativeDay(DateTime dt) {
    final days = DateTime.now().difference(dt).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    return '$days days ago';
  }
}

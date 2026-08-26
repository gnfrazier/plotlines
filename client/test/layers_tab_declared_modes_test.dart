// FR144/N0 AC — "the layer picker states which modes it derived its initial
// state from," and "changing the [declared mode] set updates layer defaults
// for days the Author has not overridden and leaves overridden days alone"
// (punchlist §4.34). `CurationClient` has no HTTP-mocked test convention in
// this repo (`curation_client_test.dart`'s own doc comment), so this fakes
// it the same way `current_trip_provider_generate_target_distance_test.dart`
// fakes `RoutingClient`.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/state/layer_selection_provider.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// Per-mode defaults, so the union across a multi-mode trip is observable —
/// mirrors how the real sidecar's `resolve_default_layers` varies by mode.
class _FakeCurationClient extends CurationClient {
  _FakeCurationClient() : super('http://fake');

  @override
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async {
    final defaults = switch (mode) {
      'cycling' => {'sight', 'natural'},
      'hiking' => {'natural', 'amenity'},
      _ => {'sight'},
    };
    return LayerCatalog(
      layers: const ['sight', 'amenity', 'natural', 'historic', 'leisure', 'man_made'],
      defaultLive: defaults,
      rulesetVersion: '1.0.0',
    );
  }
}

Widget _harness(Trip trip, {String? activeDayId}) {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  return ProviderScope(
    overrides: [
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      curationClientProvider.overrideWithValue(_FakeCurationClient()),
      appDatabaseProvider.overrideWithValue(db),
    ],
    child: MaterialApp(
      home: Scaffold(body: LayersTab(trip: trip, activeDayId: activeDayId)),
    ),
  );
}

/// Unlike [_harness] (a fresh `ProviderScope` per pump — fine for the first
/// two tests below), this keeps one `ProviderScope`/[layerSelectionProvider]
/// alive across a trip change, the same way `TripShellScreen` keeps state
/// live across a real edit — needed to prove a mode change reseeds
/// [layerSelectionProvider] rather than the test only ever seeing a fresh one.
class _MutableHarness extends StatefulWidget {
  const _MutableHarness({super.key, required this.initial, this.activeDayId});
  final Trip initial;
  final String? activeDayId;

  @override
  State<_MutableHarness> createState() => _MutableHarnessState();
}

class _MutableHarnessState extends State<_MutableHarness> {
  late Trip _trip = widget.initial;
  late final _db = AppDatabase.forTesting(NativeDatabase.memory());

  void setTrip(Trip trip) => setState(() => _trip = trip);

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
        curationClientProvider.overrideWithValue(_FakeCurationClient()),
        appDatabaseProvider.overrideWithValue(_db),
      ],
      child: MaterialApp(
        home: Scaffold(body: LayersTab(trip: _trip, activeDayId: widget.activeDayId)),
      ),
    );
  }
}

/// The map (`CandidateMap`/flutter_map) leaves a ticker a single `pump()`
/// doesn't settle — same treatment other map-bearing tests in this repo use.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('states which declared mode its defaults come from', (tester) async {
    final trip = Trip(
      id: 't1', title: 'Test', createdAt: '2026-08-26T00:00:00Z', updatedAt: '2026-08-26T00:00:00Z',
      declaredModes: const {'hiking'},
    );
    await tester.pumpWidget(_harness(trip));
    await _settle(tester);

    expect(find.text('Defaults from: Hike'), findsOneWidget);
  });

  testWidgets('a two-mode trip unions both modes\' defaults and names both', (tester) async {
    final trip = Trip(
      id: 't1', title: 'Test', createdAt: '2026-08-26T00:00:00Z', updatedAt: '2026-08-26T00:00:00Z',
      declaredModes: const {'cycling', 'hiking'},
    );
    await tester.pumpWidget(_harness(trip));
    await _settle(tester);

    expect(find.text('Defaults from: Ride, Hike'), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(LayersTab)));
    // cycling -> {sight, natural}, hiking -> {natural, amenity}: union.
    expect(container.read(layerSelectionProvider).tripLive, {'sight', 'natural', 'amenity'});
  });

  testWidgets('changing declared modes reseeds the trip default but leaves an override alone',
      (tester) async {
    final withOverride = Trip(
      id: 't1', title: 'Test', createdAt: '2026-08-26T00:00:00Z', updatedAt: '2026-08-26T00:00:00Z',
      declaredModes: const {'cycling'},
      days: [Day(id: 'day-1', index: 1)],
    );
    final harnessKey = GlobalKey<_MutableHarnessState>();
    await tester.pumpWidget(
      _MutableHarness(key: harnessKey, initial: withOverride, activeDayId: 'day-1'),
    );
    await _settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LayersTab)));
    expect(container.read(layerSelectionProvider).tripLive, {'sight', 'natural'});

    container.read(layerSelectionProvider.notifier).setDayOverride('day-1', {'historic'});

    // An Author edit mid-session, same trip identity, same provider
    // container — the trip default reseeds; the day override doesn't.
    harnessKey.currentState!.setTrip(withOverride.copyWith(declaredModes: {'hiking'}));
    await _settle(tester);

    expect(find.text('Defaults from: Hike'), findsOneWidget);
    expect(container.read(layerSelectionProvider).tripLive, {'natural', 'amenity'});
    expect(container.read(layerSelectionProvider).liveFor('day-1'), {'historic'});
  });
}

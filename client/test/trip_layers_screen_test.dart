// Issue #316 — the trip-creation layer step. It sits between the extent step
// and the first route: the Author sees the mode-derived live layer set,
// with the full catalog to override, before a route is drawn. It is
// skippable on the default, and kicks candidate extraction off on Continue
// so it is warming while the Author fills in New Route.
//
// `CurationClient` has no HTTP-mock convention in this repo
// (`curation_client_test.dart`'s note); it is faked as in
// `layers_tab_declared_modes_test.dart`.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/trip_layers_screen.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/layer_selection_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

class _FakeCurationClient extends CurationClient {
  _FakeCurationClient() : super('http://fake');

  int candidateCalls = 0;
  Set<String>? lastLiveLayers;

  @override
  Future<LayerCatalog> layerCatalog(
      {required String mode, required String dayType}) async {
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

  @override
  Future<List<Candidate>> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async {
    candidateCalls++;
    lastLiveLayers = liveLayers;
    return const [];
  }
}

ProviderContainer _container(_FakeCurationClient curation) {
  final c = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      curationClientProvider.overrideWithValue(curation),
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(_bbox)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// `/start` → push the layer step with a real `extra`; `/new` records that it
/// was reached and with what, the way New Route's `initialCenter` arrives.
Widget _harness(ProviderContainer container, {required void Function(Object?) onNew}) {
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(
        path: '/start',
        builder: (context, _) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => context.push('/new-trip-layers', extra: const [1.5, 2.5]),
              child: const Text('start'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/new-trip-layers',
        builder: (context, state) =>
            TripLayersScreen(initialCenter: state.extra as List<double>?),
      ),
      GoRoute(
        path: '/new',
        builder: (context, state) {
          onNew(state.extra);
          return const SizedBox.shrink();
        },
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _openStep(WidgetTester tester, ProviderContainer container,
    {Set<String> modes = const {'hiking'}, void Function(Object?)? onNew}) async {
  container.read(currentTripProvider.notifier).setDeclaredModes(modes);
  await tester.pumpWidget(_harness(container, onNew: onNew ?? (_) {}));
  await tester.tap(find.text('start'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('states which declared modes its defaults come from', (tester) async {
    final container = _container(_FakeCurationClient());
    await _openStep(tester, container, modes: {'cycling', 'hiking'});

    expect(find.text('Defaults from: Ride, Hike'), findsOneWidget);
    expect(find.textContaining('STEP 3 OF 4'), findsOneWidget);
  });

  testWidgets('seeds the trip-wide live set from the mode-derived default', (tester) async {
    final container = _container(_FakeCurationClient());
    await _openStep(tester, container, modes: {'hiking'});

    // hiking -> {natural, amenity} in the fake.
    expect(container.read(layerSelectionProvider).tripLive, {'natural', 'amenity'});
  });

  testWidgets('toggling a layer updates the trip set and offers a reset', (tester) async {
    final container = _container(_FakeCurationClient());
    await _openStep(tester, container, modes: {'hiking'});

    expect(find.text('Reset to defaults'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Sightseeing'));
    await tester.pumpAndSettle();
    expect(container.read(layerSelectionProvider).tripLive, {'natural', 'amenity', 'sight'});

    expect(find.text('Reset to defaults'), findsOneWidget);
    await tester.ensureVisible(find.text('Reset to defaults'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to defaults'));
    await tester.pumpAndSettle();
    expect(container.read(layerSelectionProvider).tripLive, {'natural', 'amenity'});
  });

  testWidgets('Continue proceeds on the untouched default and forwards the centre',
      (tester) async {
    final curation = _FakeCurationClient();
    final container = _container(curation);
    Object? newExtra;
    var reachedNew = false;
    await _openStep(tester, container, modes: {'hiking'}, onNew: (e) {
      reachedNew = true;
      newExtra = e;
    });

    // Skippable: never touched a chip.
    final continueBtn =
        tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Continue'));
    expect(continueBtn.onPressed, isNotNull);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(reachedNew, isTrue);
    expect(newExtra, const [1.5, 2.5]);
  });

  testWidgets('Continue kicks candidate extraction off on the settled live set',
      (tester) async {
    final curation = _FakeCurationClient();
    final container = _container(curation);
    await _openStep(tester, container, modes: {'hiking'});

    await tester.tap(find.widgetWithText(FilterChip, 'Sightseeing'));
    await tester.pumpAndSettle();

    expect(curation.candidateCalls, 0); // not before Continue
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(curation.candidateCalls, 1);
    expect(curation.lastLiveLayers, {'natural', 'amenity', 'sight'});
    expect(container.read(tripCandidatesProvider).candidates, isEmpty); // fake returns none, cleanly
    expect(container.read(tripCandidatesProvider).isCurrentFor(_bbox, {'natural', 'amenity', 'sight'}),
        isTrue);
  });
}

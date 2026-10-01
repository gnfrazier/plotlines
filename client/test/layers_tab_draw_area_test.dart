// Issue #571 — with no trip bbox the Candidates view said "Draw a trip area
// to find candidates" as a disabled label, and the only way to draw one was
// the app bar's unlabeled `crop_free` icon. Every reopened trip lands here
// (#570), and Pi QA of #478 could not find a way out. The prompt is now the
// affordance: with no bbox it opens `/trip-area`.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

class _CatalogOnlyCurationClient extends CurationClient {
  _CatalogOnlyCurationClient() : super('http://fake');

  @override
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async =>
      const LayerCatalog(
        layers: ['sight', 'amenity', 'natural', 'historic', 'leisure', 'man_made'],
        defaultLive: {'historic'},
        rulesetVersion: '1.0.0',
      );
}

/// The map inside the tab leaves a ticker `pumpAndSettle()` can't drain —
/// same treatment the other Layers tab tests use.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ProviderContainer _openTrip({TripBbox? bbox}) {
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      curationClientProvider.overrideWithValue(_CatalogOnlyCurationClient()),
      if (bbox != null) tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(bbox)),
    ],
  );
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-09-21T00:00:00Z',
          updatedAt: '2026-09-21T00:00:00Z',
          modes: const {'cycling'},
          days: [Day(id: 'day-1', index: 1)],
        ),
      );
  return container;
}

Widget _harness(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: Consumer(builder: (context, ref, _) {
            final trip = ref.watch(currentTripProvider);
            return LayersTab(trip: trip, activeDayId: 'day-1');
          }),
        ),
      ),
      GoRoute(path: '/trip-area', builder: (_, _) => const Scaffold(body: Text('TRIP AREA'))),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('with no trip area, the candidates prompt opens the trip-area screen',
      (tester) async {
    final container = _openTrip();
    await tester.pumpWidget(_harness(container));
    await _settle(tester);

    expect(find.text('Find candidates here'), findsNothing);
    await tester.tap(find.text('Draw trip area'));
    await _settle(tester);

    expect(find.text('TRIP AREA'), findsOneWidget);
  });

  testWidgets('with a trip area, the prompt finds candidates instead', (tester) async {
    final container = _openTrip(bbox: _bbox);
    await tester.pumpWidget(_harness(container));
    await _settle(tester);

    expect(find.text('Find candidates here'), findsOneWidget);
    expect(find.text('Draw trip area'), findsNothing);
  });
}

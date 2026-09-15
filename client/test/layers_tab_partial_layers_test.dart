// Issue #415 (closing the loop on #400 / SPIKE-D #159) — `GET /candidates`
// serves what it can and names the layers it could not, and the Layers tab
// used to keep only the candidates: an Author whose plugin layer timed out
// saw fewer candidates and no notice, which reads as an empty area. This
// pins the tab's treatment of the two shapes the sidecar returns through a
// 200:
//
//   partial — some live layers served: `layersPartiallyServed`, a card
//     beside the candidates that did arrive, one bounded line per missing
//     layer, "what still works", and a retry scoped to the missing layers;
//   total — nothing served: `layerExtractionFailed`, the retry re-runs the
//     whole extraction.
//
// The wire reason (`failed:TimeoutError`) never reaches a Text — FR145.
//
// `CurationClient` is faked as `layers_catalog_error_surface_test.dart`
// fakes it.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/presentation/widgets/desktop_error_surface.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

Candidate _c(String id, String layer) => Candidate(
      id: id,
      coord: const [-105.2, 40.0],
      layer: layer,
      salience: 0.5,
      roleAffinity: RoleAffinity.narrative,
      title: id,
    );

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

class _ScriptedCurationClient extends CurationClient {
  _ScriptedCurationClient() : super('http://fake');

  final List<Set<String>> requested = [];
  CandidateExtraction next = const CandidateExtraction(candidates: []);

  @override
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async =>
      LayerCatalog(
        layers: const ['sight', 'amenity', 'natural', 'historic', 'leisure', 'man_made'],
        defaultLive: const {'sight', 'natural'},
        rulesetVersion: '1.0.0',
      );

  @override
  Future<CandidateExtraction> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async {
    requested.add(liveLayers);
    return next;
  }
}

Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(
          body: LayersTab(
            trip: Trip(
              id: 't1',
              title: 'Test',
              createdAt: '2026-09-15T00:00:00Z',
              updatedAt: '2026-09-15T00:00:00Z',
              declaredModes: const {'cycling'},
            ),
            activeDayId: null,
          ),
        ),
      ),
    );

ProviderContainer _container(_ScriptedCurationClient curation) {
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

/// The map inside the tab leaves a ticker `pumpAndSettle()` can't drain.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('a partially served run shows the card beside the candidates, naming each missing layer',
      (tester) async {
    final curation = _ScriptedCurationClient()
      ..next = CandidateExtraction(
        candidates: [_c('a', 'sight'), _c('b', 'sight')],
        layersServed: const ['sight'],
        layersUnavailable: const {'natural': 'failed:TimeoutError', 'historic': 'loading'},
      );
    final container = _container(curation);
    await tester.pumpWidget(_harness(container));
    await _settle(tester);
    await container
        .read(tripCandidatesProvider.notifier)
        .fetch(bbox: _bbox, liveLayers: {'sight', 'natural', 'historic'});
    await _settle(tester);

    final surface = tester.widget<DesktopErrorSurface>(find.byType(DesktopErrorSurface));
    expect(surface.state, DesktopErrorState.layersPartiallyServed);
    expect(find.text('not every requested layer is in these results'), findsOneWidget);
    // One bounded line per missing layer — the layer's label and a phrase
    // from the table, never the wire string.
    expect(find.text('Natural — layer extraction did not finish.'), findsOneWidget);
    expect(find.text('Historic — it is still being prepared.'), findsOneWidget);
    expect(find.textContaining('TimeoutError'), findsNothing);
    expect(find.textContaining('failed:'), findsNothing);
    // What still works: the served candidates and their layers.
    expect(find.text('2 candidates'), findsOneWidget);
    expect(find.text('On the map: Sightseeing.'), findsOneWidget);
    expect(find.text('Retry those layers'), findsOneWidget);
  });

  testWidgets('Retry those layers re-requests only the missing layers and clears the card when they serve',
      (tester) async {
    final curation = _ScriptedCurationClient()
      ..next = CandidateExtraction(
        candidates: [_c('a', 'sight')],
        layersServed: const ['sight'],
        layersUnavailable: const {'historic': 'loading'},
      );
    final container = _container(curation);
    await tester.pumpWidget(_harness(container));
    await _settle(tester);
    await container
        .read(tripCandidatesProvider.notifier)
        .fetch(bbox: _bbox, liveLayers: {'sight', 'historic'});
    await _settle(tester);
    expect(find.byType(DesktopErrorSurface), findsOneWidget);

    curation.next = CandidateExtraction(
      candidates: [_c('h', 'historic')],
      layersServed: const ['historic'],
    );
    await tester.tap(find.text('Retry those layers'));
    await _settle(tester);

    expect(curation.requested.last, {'historic'},
        reason: 'the served layer is not re-fetched');
    expect(find.byType(DesktopErrorSurface), findsNothing);
    final state = container.read(tripCandidatesProvider);
    expect(state.candidates.map((c) => c.id), ['a', 'h']);
  });

  testWidgets('nothing served is layer-extraction-failed, and its Retry re-runs the whole set',
      (tester) async {
    final curation = _ScriptedCurationClient()
      ..next = const CandidateExtraction(
        candidates: [],
        layersServed: [],
        layersUnavailable: {'sight': 'failed:ConnectionError', 'natural': 'failed:ConnectionError'},
      );
    final container = _container(curation);
    await tester.pumpWidget(_harness(container));
    await _settle(tester);
    await container
        .read(tripCandidatesProvider.notifier)
        .fetch(bbox: _bbox, liveLayers: {'sight', 'natural'});
    await _settle(tester);

    final surface = tester.widget<DesktopErrorSurface>(find.byType(DesktopErrorSurface));
    expect(surface.state, DesktopErrorState.layerExtractionFailed);
    expect(find.text('layer extraction did not finish'), findsOneWidget);
    expect(find.textContaining('ConnectionError'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(curation.requested.last, {'sight', 'natural'});
  });

  testWidgets('a fully served run shows no card', (tester) async {
    final curation = _ScriptedCurationClient()
      ..next = CandidateExtraction(
        candidates: [_c('a', 'sight')],
        layersServed: const ['sight', 'natural'],
      );
    final container = _container(curation);
    await tester.pumpWidget(_harness(container));
    await _settle(tester);
    await container
        .read(tripCandidatesProvider.notifier)
        .fetch(bbox: _bbox, liveLayers: {'sight', 'natural'});
    await _settle(tester);
    expect(find.byType(DesktopErrorSurface), findsNothing);
  });
}

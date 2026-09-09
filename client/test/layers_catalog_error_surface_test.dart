// Issue #317 — the Layers tab (and the trip-creation layer step) used to
// interpolate the caught error straight into a `Text`:
//
//     Text('Could not load the layer catalog: $err')
//
// where `$err` is a `CurationException`, whose `toString()` is the class
// name, the HTTP status and the raw response body — the Author saw
// `CurationException(500): Internal Server Error` centred in red, with no
// retry and no way forward. This is the exact shape M13 (#143) exists to
// prevent: every desktop failure goes through one shared surface with a
// sentence, a cause and an action.
//
// Part A of the issue: route both sites through `DesktopErrorSurface`. Part B
// (the 500 itself) does not reproduce on current `main` and is closed with
// that stated — see the PR.
//
// `CurationClient` has no HTTP-mock convention in this repo
// (`curation_client_test.dart`'s note); it is faked as elsewhere.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/presentation/screens/trip_layers_screen.dart';
import 'package:plotlines_client/presentation/widgets/desktop_error_surface.dart';
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

/// Fails the `/layers` fetch with the exact exception the walkthrough hit,
/// until [heal] is called — so a test can prove the Retry actually re-runs
/// the provider and recovers.
class _FlakyCurationClient extends CurationClient {
  _FlakyCurationClient() : super('http://fake');

  bool healthy = false;
  int layerCatalogCalls = 0;

  void heal() => healthy = true;

  @override
  Future<LayerCatalog> layerCatalog(
      {required String mode, required String dayType}) async {
    layerCatalogCalls++;
    if (!healthy) {
      throw CurationException(500, '{"detail":"Internal Server Error"}');
    }
    return LayerCatalog(
      layers: const ['sight', 'amenity', 'natural', 'historic', 'leisure', 'man_made'],
      defaultLive: const {'sight', 'natural'},
      rulesetVersion: '1.0.0',
    );
  }

  @override
  Future<List<Candidate>> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async =>
      const [];
}

/// The bounded cause phrase for `layerExtractionFailed`
/// (`message_catalog.dart`), and the raw-exception fragments that must never
/// reach the Author.
const _causePhrase = 'layer extraction did not finish';
const _rawFragments = [
  'CurationException',
  'CurationException(500)',
  'Internal Server Error',
  'Could not load the layer catalog',
];

/// The map (`CandidateMap`/flutter_map) inside the Layers tab leaves a ticker
/// a single `pumpAndSettle()` can't drain — same treatment the other
/// map-bearing tests in this repo use.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _expectSharedSurfaceNotRawException(WidgetTester tester) {
  expect(find.byType(DesktopErrorSurface), findsOneWidget,
      reason: 'the failure must render through M13\'s shared surface');
  expect(find.text(_causePhrase), findsOneWidget,
      reason: 'the cause is a bounded phrase from reasonPhrases, not "$_causePhrase" interpolated');
  expect(find.text('Retry'), findsOneWidget,
      reason: 'the shared surface offers a way forward');
  for (final fragment in _rawFragments) {
    expect(find.textContaining(fragment), findsNothing,
        reason: 'no exception repr / raw string reaches a user-visible Text: "$fragment"');
  }
}

Widget _layersTabHarness(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(
        body: LayersTab(
          trip: Trip(
            id: 't1',
            title: 'Test',
            createdAt: '2026-09-09T00:00:00Z',
            updatedAt: '2026-09-09T00:00:00Z',
            declaredModes: const {'cycling'},
          ),
          activeDayId: null,
        ),
      ),
    ),
  );
}

ProviderContainer _container(_FlakyCurationClient curation) {
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

void main() {
  group('Layers tab — a /layers failure', () {
    testWidgets('renders through the shared desktop error surface, not a raw CurationException',
        (tester) async {
      final curation = _FlakyCurationClient();
      await tester.pumpWidget(_layersTabHarness(_container(curation)));
      await tester.pumpAndSettle();

      _expectSharedSurfaceNotRawException(tester);
    });

    testWidgets('Retry re-runs the catalog fetch and recovers', (tester) async {
      final curation = _FlakyCurationClient();
      await tester.pumpWidget(_layersTabHarness(_container(curation)));
      await tester.pumpAndSettle();
      expect(curation.layerCatalogCalls, 1);

      curation.heal();
      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(curation.layerCatalogCalls, greaterThan(1),
          reason: 'Retry must re-run layerCatalogProvider');
      expect(find.byType(DesktopErrorSurface), findsNothing);
      expect(find.text('Trip layers'), findsOneWidget); // the picker rail is back
    });
  });

  group('Trip-creation layer step — a /layers failure', () {
    Widget harness(ProviderContainer container) {
      final router = GoRouter(
        initialLocation: '/step',
        routes: [
          GoRoute(path: '/step', builder: (_, _) => const TripLayersScreen()),
          GoRoute(path: '/new', builder: (_, _) => const SizedBox.shrink()),
        ],
      );
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: PlotTheme.light(),
          routerConfig: router,
        ),
      );
    }

    testWidgets('renders through the shared desktop error surface, not a raw CurationException',
        (tester) async {
      final curation = _FlakyCurationClient();
      final container = _container(curation);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});
      await tester.pumpWidget(harness(container));
      await tester.pumpAndSettle();

      _expectSharedSurfaceNotRawException(tester);
    });

    testWidgets('Retry re-runs the catalog fetch and recovers', (tester) async {
      final curation = _FlakyCurationClient();
      final container = _container(curation);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});
      await tester.pumpWidget(harness(container));
      await tester.pumpAndSettle();

      curation.heal();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopErrorSurface), findsNothing);
      expect(find.text('Choose what the map shows you'), findsOneWidget);
    });
  });

  // The general guard the issue asks for: "an `err`/exception object
  // interpolated into a user-visible `Text` is the thing to ban, not this one
  // line." A grep over the Presentation layer, no toolchain — the same shape
  // as `reveal_gate_lint_test.dart`.
  //
  // One line is knowingly still on the old pattern and is out of scope for
  // #317: `trip_library_screen.dart`, a local-DB read failure with no clean
  // M13 state to route to. It is filed separately; when that lands, delete it
  // from this allowlist.
  group('no exception object is interpolated into a user-visible Text', () {
    final presentationDir = Directory('lib/presentation');
    const allowlist = {'lib/presentation/screens/trip_library_screen.dart'};

    // A `Text(...)` on one line that interpolates a caught error object —
    // `$err` / `${error}` / `$exception` / `$ex` / `$stackTrace`. Apostrophes
    // inside the string must not stop the scan, so this is line-based rather
    // than string-literal-aware.
    final offenders = RegExp(
      r'''Text\([^\n]*\$\{?(?:err|error|exception|ex|stackTrace)''',
    );

    test('lib/presentation carries no new occurrences', () {
      final hits = <String>[];
      for (final entity in presentationDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.replaceAll(r'\', '/');
        if (allowlist.contains(rel)) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (offenders.hasMatch(lines[i])) {
            hits.add('$rel:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(hits, isEmpty,
          reason: 'route the failure through DesktopErrorSurface with a bounded '
              'cause phrase instead of interpolating the caught error:\n${hits.join('\n')}');
    });

    test('the allowlisted debt still exists (delete the entry when it is fixed)', () {
      for (final rel in allowlist) {
        final f = File(rel);
        expect(f.existsSync(), isTrue, reason: '$rel moved — update the allowlist');
        expect(offenders.hasMatch(f.readAsStringSync()), isTrue,
            reason: '$rel no longer matches — remove it from the allowlist');
      }
    });
  });
}

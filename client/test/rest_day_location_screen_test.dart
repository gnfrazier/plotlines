// Issue #325 — the full-height rest-day location picker, tested in
// isolation from the Logistics tab (which
// `logistics_tab_rest_day_test.dart` covers end to end). Each case maps to
// one of the issue's acceptance criteria.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart' show GeocodeResult;
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/attribution_line.dart' show nominatimSearchAttribution;
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
import 'package:plotlines_client/presentation/screens/rest_day_location_screen.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _hotel = Candidate(
  id: 'hotel-1',
  coord: [-105.27, 40.02],
  layer: 'amenity',
  salience: 0.55,
  roleAffinity: RoleAffinity.station,
  title: 'Grand Hotel',
  tags: {'tourism': 'hotel'},
);

/// Pumps a screen with one button that opens the picker and records what it
/// returned, so each test drives the picker the way `_RestDayDetails`
/// actually does.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<Candidate> candidates = const [],
  List<List<List<double>>> routeLines = const [],
  double? bufferM,
  Future<List<GeocodeResult>> Function(String query)? geocode,
  void Function(RestDayLocationChoice?)? onResult,
}) async {
  final container = ProviderContainer(overrides: [
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
  ]);
  addTearDown(container.dispose);
  if (candidates.isNotEmpty) {
    container.read(tripCandidatesProvider.notifier).state =
        TripCandidatesState(candidates: candidates);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () async {
              final choice = await showRestDayLocationScreen(
                context,
                routeLines: routeLines,
                bufferM: bufferM,
                geocode: geocode ?? (_) async => const [],
              );
              onResult?.call(choice);
            },
            child: const Text('open'),
          );
        }),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return container;
}

void main() {
  testWidgets('is a full-height screen, not a dialog card', (tester) async {
    await _pump(tester);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Set rest day location'), findsOneWidget);
    expect(find.byType(CandidateMap), findsOneWidget);
  });

  testWidgets(
      'typing alone never geocodes — only submitting does (issue #249: Nominatim usage policy '
      'forbids per-keystroke autocomplete)', (tester) async {
    var calls = 0;
    await _pump(tester, geocode: (_) async {
      calls++;
      return const [];
    });

    await tester.enterText(find.byType(TextField), 'B');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Boulder');
    await tester.pump();

    expect(calls, 0);
  });

  testWidgets('submitting a search shows results plus the Nominatim credit next to them',
      (tester) async {
    await _pump(tester, geocode: (query) async {
      expect(query, 'Boulder, CO');
      return const [GeocodeResult(label: 'Boulder, CO', coord: [-105.27, 40.02])];
    });

    await tester.enterText(find.byType(TextField), 'Boulder, CO');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    expect(find.text('Boulder, CO'), findsWidgets);
    // Issue #296 — present wherever a geocoded result is displayed.
    expect(find.text(nominatimSearchAttribution), findsOneWidget);
  });

  testWidgets('picking a search result shows it as the resolved place, confirm returns it',
      (tester) async {
    RestDayLocationChoice? result;
    await _pump(
      tester,
      geocode: (_) async => const [GeocodeResult(label: 'Boulder, CO', coord: [-105.27, 40.02])],
      onResult: (r) => result = r,
    );

    await tester.enterText(find.byType(TextField), 'Boulder');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    await tester.tap(find.text('Boulder, CO').last);
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await _settle(tester);

    expect(result?.coord, const [-105.27, 40.02]);
    expect(result?.label, 'Boulder, CO');
  });

  testWidgets("candidate markers from the Author's live layer selection are browsable",
      (tester) async {
    RestDayLocationChoice? result;
    await _pump(tester, candidates: const [_hotel], onResult: (r) => result = r);

    expect(find.byTooltip('Grand Hotel'), findsOneWidget);
    await tester.tap(find.byTooltip('Grand Hotel'));
    await tester.pump();
    expect(find.text('Grand Hotel'), findsWidgets); // shown in the confirm bar

    await tester.tap(find.text('Confirm'));
    await _settle(tester);
    expect(result?.coord, _hotel.coord);
    expect(result?.label, 'Grand Hotel');
  });

  testWidgets('a raw map tap places a point with no label — hand-placement stays skippable',
      (tester) async {
    RestDayLocationChoice? result;
    await _pump(tester, onResult: (r) => result = r);

    final map = tester.widget<CandidateMap>(find.byType(CandidateMap));
    map.onMapTap!(const [-105.2, 40.05]);
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await _settle(tester);

    expect(result?.coord, const [-105.2, 40.05]);
    expect(result?.label, isNull);
  });

  testWidgets('Cancel returns null without picking anything', (tester) async {
    RestDayLocationChoice? result;
    var resultSet = false;
    await _pump(tester, onResult: (r) {
      result = r;
      resultSet = true;
    });

    await tester.tap(find.text('Cancel'));
    await _settle(tester);

    expect(resultSet, isTrue);
    expect(result, isNull);
  });

  testWidgets('with no pick yet, Confirm is disabled', (tester) async {
    await _pump(tester);
    final confirm =
        tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
    expect(confirm.onPressed, isNull);
  });

  testWidgets('the route buffer frames the initial extent when a route and buffer both exist',
      (tester) async {
    await _pump(
      tester,
      routeLines: const [
        [
          [-105.30, 40.00],
          [-105.20, 40.10],
        ],
      ],
      bufferM: 5000,
    );

    final map = tester.widget<CandidateMap>(find.byType(CandidateMap));
    expect(map.initialCameraFit, isNotNull);
  });

  testWidgets('with no route yet, there is nothing to frame or warn against', (tester) async {
    RestDayLocationChoice? result;
    await _pump(tester, bufferM: 5000, onResult: (r) => result = r);

    final map = tester.widget<CandidateMap>(find.byType(CandidateMap));
    expect(map.initialCameraFit, isNull);

    map.onMapTap!(const [40.0, 80.0]); // absurdly far from anything
    await tester.pump();
    expect(find.textContaining('outside'), findsNothing);

    await tester.tap(find.text('Confirm'));
    await _settle(tester);
    expect(result?.coord, const [40.0, 80.0]); // never blocked
  });

  testWidgets('a pick outside the buffer warns but never blocks confirming', (tester) async {
    RestDayLocationChoice? result;
    await _pump(
      tester,
      routeLines: const [
        [
          [-105.30, 40.00],
          [-105.29, 40.00],
        ],
      ],
      bufferM: 500, // 500 m — the far pick below is much farther than that
      onResult: (r) => result = r,
    );

    final map = tester.widget<CandidateMap>(find.byType(CandidateMap));
    map.onMapTap!(const [-104.0, 41.0]); // well outside the buffer
    await tester.pump();

    expect(find.textContaining("outside the trip's offline buffer"), findsOneWidget);
    final confirm =
        tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Confirm'));
    expect(confirm.onPressed, isNotNull); // AC: warns, never blocks

    await tester.tap(find.text('Confirm'));
    await _settle(tester);
    expect(result?.coord, const [-104.0, 41.0]);
  });

  testWidgets('a pick inside the buffer shows no warning', (tester) async {
    await _pump(
      tester,
      routeLines: const [
        [
          [-105.30, 40.00],
          [-105.20, 40.00],
        ],
      ],
      bufferM: 5000,
    );

    final map = tester.widget<CandidateMap>(find.byType(CandidateMap));
    map.onMapTap!(const [-105.25, 40.001]); // right beside the route
    await tester.pump();

    expect(find.textContaining('outside'), findsNothing);
  });
}

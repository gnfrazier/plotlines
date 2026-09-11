// Story C7 (issue #43), FR23 — "Authors filter and place lodging/campground
// options on the planning map by type." Covers the Logistics tab's LODGING
// section: the type filter chips narrow which candidates the map dialog
// shows ("overlays update with filters"), and placing one attaches a POI
// node — carrying the specific lodging type, not the bare layer id — to the
// day it was placed from ("placed lodging attaches to the day").
//
// `CurationClient` has no HTTP-mock convention in this repo
// (`curation_client_test.dart`'s own note); faked the same way
// `trip_candidates_provider_test.dart` fakes it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';
import 'support/display_units.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

class _FakeCurationClient extends CurationClient {
  _FakeCurationClient() : super('http://fake');

  List<Candidate> result = const [];

  @override
  Future<List<Candidate>> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async =>
      result;
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

const _campsite = Candidate(
  id: 'camp-1',
  coord: [-105.28, 40.03],
  layer: 'amenity',
  salience: 0.55,
  roleAffinity: RoleAffinity.station,
  title: 'Pine Camp',
  tags: {'tourism': 'camp_site'},
);

const _sight = Candidate(
  id: 'sight-1',
  coord: [-105.29, 40.01],
  layer: 'historic',
  salience: 0.6,
  roleAffinity: RoleAffinity.narrative,
  title: 'Old Fort',
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Day day, {
  List<Candidate> candidates = const [],
}) async {
  final container = ProviderContainer(overrides: [
    metricUnits(),
    curationClientProvider.overrideWithValue(_FakeCurationClient()..result = candidates),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [day],
        ),
      );
  if (candidates.isNotEmpty) {
    await container
        .read(tripCandidatesProvider.notifier)
        .fetch(bbox: _bbox, liveLayers: {'amenity', 'historic'});
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => LogisticsTab(
              trip: ref.watch(currentTripProvider),
              onOpenSegment: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return container;
}

void main() {
  testWidgets('shows the four lodging type filter chips, all selected by default', (tester) async {
    await _pump(tester, Day(id: 'd1', index: 1));
    for (final label in ['Campsite', 'Hotel', 'Hut', 'Hostel']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('with no candidates ever fetched, "Place lodging on map" is disabled', (tester) async {
    await _pump(tester, Day(id: 'd1', index: 1));

    final button = tester.widget<PlotButton>(find.widgetWithText(PlotButton, 'Place lodging on map'));
    expect(button.onPressed, isNull);
    expect(find.textContaining('Find candidates on the Layers tab first'), findsOneWidget);
  });

  testWidgets('opening the map shows only lodging candidates, never a plain sight', (tester) async {
    await _pump(tester, Day(id: 'd1', index: 1), candidates: [_hotel, _campsite, _sight]);

    await tester.ensureVisible(find.text('Place lodging on map'));
    await tester.pump();
    await tester.tap(find.text('Place lodging on map'));
    await _settle(tester);

    final map = tester.widget<CandidateMap>(find.byType(CandidateMap));
    expect(map.candidates.map((c) => c.id).toSet(), {'hotel-1', 'camp-1'});
  });

  testWidgets('deselecting the Hotel chip narrows the map overlays — "overlays update with filters"',
      (tester) async {
    await _pump(tester, Day(id: 'd1', index: 1), candidates: [_hotel, _campsite, _sight]);

    await tester.ensureVisible(find.text('Hotel'));
    await tester.pump();
    await tester.tap(find.text('Hotel'));
    await tester.pump();
    await tester.ensureVisible(find.text('Place lodging on map'));
    await tester.pump();
    await tester.tap(find.text('Place lodging on map'));
    await _settle(tester);

    final map = tester.widget<CandidateMap>(find.byType(CandidateMap));
    expect(map.candidates.map((c) => c.id), ['camp-1']);
  });

  testWidgets('tapping a candidate on the map attaches it to the day it was placed from',
      (tester) async {
    final container =
        await _pump(tester, Day(id: 'd1', index: 1), candidates: [_hotel, _campsite]);

    await tester.ensureVisible(find.text('Place lodging on map'));
    await tester.pump();
    await tester.tap(find.text('Place lodging on map'));
    await _settle(tester);

    await tester.tap(find.byTooltip('Grand Hotel'));
    await _settle(tester);

    final day = container.read(currentTripProvider).days.single;
    expect(day.nodes, hasLength(1));
    expect(day.nodes.single.kind, NodeKind.poi);
    expect(day.nodes.single.title, 'Grand Hotel');
    // FR23's "filter by type" only means something downstream if the placed
    // node still remembers which type it was — not the bare "amenity" layer.
    expect(day.nodes.single.poiType, 'hotel');
    expect(find.text('Grand Hotel'), findsOneWidget); // shown as a removable chip
  });

  testWidgets('removing a placed lodging node clears it from the day', (tester) async {
    final container = await _pump(
      tester,
      Day(
        id: 'd1',
        index: 1,
        nodes: [
          Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0], title: 'Grand Hotel', poiType: 'hotel'),
        ],
      ),
    );

    expect(find.text('Grand Hotel'), findsOneWidget);
    final deleteIcon = find.descendant(of: find.byType(Chip), matching: find.byIcon(Icons.cancel));
    await tester.ensureVisible(deleteIcon);
    await tester.pump();
    await tester.tap(deleteIcon);
    await tester.pump();

    expect(container.read(currentTripProvider).days.single.nodes, isEmpty);
  });
}

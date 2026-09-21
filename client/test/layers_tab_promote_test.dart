// Issue #477 — the Layers tab's FR99 "promote directly from the map" tap
// used to append a day-scoped `Node` (`CurrentTripNotifier.promoteCandidate`,
// N3's stand-in from before O1's Anchor/role model existed) and never
// touched `Trip.anchors`, a role set, or the candidate's own provenance/area
// (`domain/promote.dart`'s `provenanceFromCandidate`/`areaFromCandidate`,
// #403). This pins the fixed behaviour: a tap now runs the same
// `promoteAnchor` path the Proposals view and the hand-placed dialog use.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

Candidate _candidate({
  String id = 'c1',
  String layer = 'historic',
  RoleAffinity affinity = RoleAffinity.narrative,
  String title = 'Old Fort',
  CandidateGeometry? geometry,
}) =>
    Candidate(
      id: id,
      coord: const [-105.27, 40.02],
      layer: layer,
      salience: 0.8,
      roleAffinity: affinity,
      title: title,
      tags: const {'historic': 'fort'},
      geometry: geometry,
    );

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// Serves whatever [next] holds for any live-layer set, same shape as
/// `layers_tab_partial_layers_test.dart`'s `_ScriptedCurationClient`.
class _ScriptedCurationClient extends CurationClient {
  _ScriptedCurationClient() : super('http://fake');
  List<Candidate> next = const [];

  @override
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async =>
      const LayerCatalog(
        layers: ['sight', 'amenity', 'natural', 'historic', 'leisure', 'man_made'],
        defaultLive: {'historic'},
        rulesetVersion: '1.0.0',
      );

  @override
  Future<CandidateExtraction> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async =>
      CandidateExtraction(candidates: next, layersServed: liveLayers.toList());
}

/// The map inside the tab leaves a ticker `pumpAndSettle()` can't drain —
/// same treatment the other Layers tab tests use.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ProviderContainer _openTrip(_ScriptedCurationClient curation, {List<Day> days = const []}) {
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      curationClientProvider.overrideWithValue(curation),
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(_bbox)),
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
          days: days,
        ),
      );
  return container;
}

/// Rebuilds `LayersTab` from `currentTripProvider` on every change, the way
/// `trip_shell_screen.dart` does — the real app never passes a stale `trip`.
Widget _harness(ProviderContainer container, {String? activeDayId}) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            final trip = ref.watch(currentTripProvider);
            return LayersTab(trip: trip, activeDayId: activeDayId);
          }),
        ),
      ),
    );

void main() {
  testWidgets(
      'tapping a candidate promotes an Anchor attached to the active day, not a day Node',
      (tester) async {
    final curation = _ScriptedCurationClient()..next = [_candidate()];
    final container = _openTrip(curation, days: [Day(id: 'day-1', index: 1)]);
    await tester.pumpWidget(_harness(container, activeDayId: 'day-1'));
    await _settle(tester);
    await container.read(tripCandidatesProvider.notifier).fetch(bbox: _bbox, liveLayers: {'historic'});
    await _settle(tester);

    await tester.tap(find.byTooltip('Old Fort'));
    await tester.pump();

    final trip = container.read(currentTripProvider);
    expect(trip.anchors, hasLength(1));
    final anchor = trip.anchors.single;
    expect(anchor.title, 'Old Fort');
    expect(anchor.coord, const [-105.27, 40.02]);
    // FR106 / §4.2 — provenance and tags copied from the candidate, not
    // referenced, via `provenanceFromCandidate`.
    expect(anchor.provenance?.kind, AnchorSourceKind.candidate);
    expect(anchor.provenance?.sourceId, 'c1');
    expect(anchor.provenance?.layer, 'historic');
    expect(anchor.provenance?.tags, const {'historic': 'fort'});
    // The candidate's role affinity pre-fills exactly one role
    // (`roleKindFromAffinity`), attached to the active day directly.
    expect(anchor.roles, hasLength(1));
    expect(anchor.roles.single.kind, RoleKind.narrative);
    expect(anchor.roles.single.dayId, 'day-1');
    // The old behaviour wrote a `Day.nodes` entry — it must not any more.
    expect(trip.days.single.nodes, isEmpty);
    expect(find.text('Promoted "Old Fort"'), findsOneWidget);
  });

  testWidgets('a point candidate\'s role affinity picks the role kind (station)',
      (tester) async {
    final curation = _ScriptedCurationClient()
      ..next = [_candidate(id: 'c2', affinity: RoleAffinity.station, title: 'Trailhead Spring')];
    final container = _openTrip(curation, days: [Day(id: 'day-1', index: 1)]);
    await tester.pumpWidget(_harness(container, activeDayId: 'day-1'));
    await _settle(tester);
    await container.read(tripCandidatesProvider.notifier).fetch(bbox: _bbox, liveLayers: {'historic'});
    await _settle(tester);

    await tester.tap(find.byTooltip('Trailhead Spring'));
    await tester.pump();

    final anchor = container.read(currentTripProvider).anchors.single;
    expect(anchor.roles.single.kind, RoleKind.station);
    expect(anchor.area, isNull);
  });

  testWidgets('a polygon candidate\'s boundary is adopted as the anchor\'s Area',
      (tester) async {
    const ring = [
      [-105.28, 40.01],
      [-105.26, 40.01],
      [-105.26, 40.03],
      [-105.28, 40.01],
    ];
    final curation = _ScriptedCurationClient()
      ..next = [
        _candidate(
          id: 'c3',
          title: 'Historic District',
          geometry: const CandidatePolygon(ring: ring),
        ),
      ];
    final container = _openTrip(curation, days: [Day(id: 'day-1', index: 1)]);
    await tester.pumpWidget(_harness(container, activeDayId: 'day-1'));
    await _settle(tester);
    await container.read(tripCandidatesProvider.notifier).fetch(bbox: _bbox, liveLayers: {'historic'});
    await _settle(tester);

    await tester.tap(find.byTooltip('Historic District'));
    await tester.pump();

    final anchor = container.read(currentTripProvider).anchors.single;
    expect(anchor.area, isNotNull);
    expect(anchor.area!.source, AreaSource.imported);
    expect(anchor.area!.rings.single, ring);
  });

  testWidgets('the Promoted panel counts anchors attached to this day, not day.nodes',
      (tester) async {
    final curation = _ScriptedCurationClient()..next = [_candidate()];
    final container = _openTrip(curation, days: [Day(id: 'day-1', index: 1)]);
    await tester.pumpWidget(_harness(container, activeDayId: 'day-1'));
    await _settle(tester);
    await container.read(tripCandidatesProvider.notifier).fetch(bbox: _bbox, liveLayers: {'historic'});
    await _settle(tester);

    expect(find.text('Promoted (0)'), findsOneWidget);

    await tester.tap(find.byTooltip('Old Fort'));
    await _settle(tester);

    expect(find.text('Promoted (1)'), findsOneWidget);
    // `PlotBadge` upper-cases its label.
    expect(find.text('OLD FORT'), findsOneWidget);
  });
}

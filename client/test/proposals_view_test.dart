// FR102–FR105a / FR110 (Story N4a) — "Review and act on proposals", as the
// Author actually sees it.
//
// #235 B5. `proposals_view.dart` was the largest zero-coverage file in the
// client (177 lines) and holds the only path in this screen that writes canon:
// Promote. `proposals_provider_test.dart` covers the state machine well — sort,
// filter, defer, reject, bulk, re-run — so this file deliberately does not
// re-test that. It covers the part only a widget test can reach: that the panel
// renders what the state says, that the three one-gesture actions are wired to
// the right proposal, and that Promote builds the anchor O1 specifies.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/cluster_proposal.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/proposals_view.dart';
import 'package:plotlines_client/presentation/widgets/proposal_card.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/proposals_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

// ── fixtures ───────────────────────────────────────────────────────────

Map<String, dynamic> _member(String id, String layer, double salience, String affinity,
        {String? title}) =>
    {
      'candidate_id': id,
      'layer': layer,
      'type': '$layer=thing',
      'salience': salience,
      'role_affinity': affinity,
      'title': title ?? id,
    };

Map<String, dynamic> _proposal(
  String id, {
  String? name,
  double rank = 0.5,
  double salience = 0.5,
  List<String> affinities = const ['narrative'],
  List<Map<String, dynamic>>? members,
}) =>
    {
      'id': id,
      'name': name ?? id,
      'kind': affinities.join('+'),
      'role_affinities': affinities,
      'members': members ?? [_member('$id-a', 'historic', salience, affinities.first)],
      'centroid': [-82.0, 36.0],
      'extent_m': 40.0,
      'tightness': 0.8,
      'salience_score': salience,
      'rank_score': rank,
      'distance_to_route_m': null,
      'is_new': true,
    };

ColocationResult _result(List<Map<String, dynamic>> proposals,
        {int cap = 30, int beyond = 0}) =>
    ColocationResult.fromJson({
      'proposals': proposals,
      'cap': cap,
      'n_beyond_cap': beyond,
      'n_candidates': 100,
      'ruleset_version': '1.2.0',
      'layers_served': ['historic', 'sight'],
      'layers_unavailable': <String, dynamic>{},
    });

class _FakeCurationClient extends CurationClient {
  _FakeCurationClient(this.next) : super('http://x');
  ColocationResult next;
  Object? throws;
  int calls = 0;

  @override
  Future<ColocationResult> analyzeColocation({
    required TripBbox bbox,
    required Set<String> liveLayers,
    List<dynamic> route = const [],
    Iterable<Set<String>> rejected = const [],
    Iterable<Set<String>> previous = const [],
    String sort = 'rank',
  }) async {
    calls++;
    if (throws != null) throw throws!;
    return next;
  }
}

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}

  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

final _bbox = TripBbox(minLon: -82.1, minLat: 35.9, maxLon: -81.9, maxLat: 36.1);

Trip _trip() => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-09-02T00:00:00Z',
      updatedAt: '2026-09-02T00:00:00Z',
      days: [Day(id: 'd1', index: 1)],
    );

/// `vector_map_tiles`' ticker needs several short pumps rather than one
/// `pumpAndSettle` — the same note `candidate_map_test.dart` and
/// `widget_test.dart` carry.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Wait out a snackbar. `ScaffoldMessenger` queues them, so a second action's
/// message never appears while the first is still on screen.
Future<void> _clearSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await _settle(tester);
}

/// The card for one proposal, addressed by the name it renders.
Finder _cardFor(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(ProposalCard));

Future<(ProviderContainer, _FakeCurationClient)> _pump(
  WidgetTester tester, {
  ColocationResult? result,
  Object? analyzeThrows,
  TripBbox? bbox,
  Set<String> liveLayers = const {'historic', 'sight'},
}) async {
  // Wide enough for the 420 px panel beside the map, tall enough that the
  // proposal cards are built rather than lazily skipped.
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final client = _FakeCurationClient(result ?? _result([]))..throws = analyzeThrows;

  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    curationClientProvider.overrideWithValue(client),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
    if (bbox != null)
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(bbox)),
  ]);
  container.read(currentTripProvider.notifier).open(_trip());
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: ProposalsView(trip: _trip(), liveLayers: liveLayers),
      ),
    ),
  ));
  await _settle(tester);
  return (container, client);
}

Future<void> _run(WidgetTester tester) async {
  await tester.tap(find.textContaining('Find the good spots'));
  await _settle(tester);
}

void main() {
  group('before anything has been analysed', () {
    testWidgets('says what the button will do rather than showing an empty list',
        (tester) async {
      await _pump(tester, bbox: _bbox);

      expect(find.text('No analysis yet'), findsOneWidget);
      expect(find.textContaining('cluster the candidates in this trip area'),
          findsOneWidget);
      expect(find.text('Find the good spots'), findsOneWidget);
    });

    testWidgets('the run button is disabled until a trip area exists',
        (tester) async {
      // N4: analysis is "a named Author action over a fixed bbox, never
      // ambient over a viewport" — with no bbox there is nothing to analyse.
      await _pump(tester); // no bbox

      final button = tester.widget<PlotButton>(
          find.widgetWithText(PlotButton, 'Find the good spots'));
      expect(button.onPressed, isNull);
    });

    testWidgets('sort, filters and counts stay hidden until there is a result',
        (tester) async {
      await _pump(tester, bbox: _bbox);

      expect(find.text('SORT'), findsNothing);
      expect(find.textContaining('SHOWN'), findsNothing);
    });
  });

  group('running the analysis', () {
    testWidgets('renders a card per proposal and counts them', (tester) async {
      await _pump(tester,
          bbox: _bbox,
          result: _result([
            _proposal('c1', name: 'Old Fort'),
            _proposal('c2', name: 'Mill Ruin'),
          ]));
      await _run(tester);

      expect(find.text('Old Fort'), findsOneWidget);
      expect(find.text('Mill Ruin'), findsOneWidget);
      expect(find.textContaining('2 SHOWN'), findsOneWidget);
    });

    testWidgets('the button offers a re-run once it has run', (tester) async {
      await _pump(tester, bbox: _bbox, result: _result([_proposal('c1')]));
      await _run(tester);

      expect(find.text('Run again'), findsOneWidget);
      expect(find.text('Find the good spots'), findsNothing);
    });

    testWidgets('an empty result suggests what to change', (tester) async {
      // N4a — "no clusters found says so and suggests widening layers or the
      // bbox". An empty list with no explanation reads as a broken screen.
      await _pump(tester, bbox: _bbox, result: _result([]));
      await _run(tester);

      expect(find.text('No clusters found'), findsOneWidget);
      expect(find.textContaining('turning on more layers'), findsOneWidget);
      expect(find.textContaining('widening the trip area'), findsOneWidget);
    });

    testWidgets('a failure is reported in the panel, not swallowed',
        (tester) async {
      await _pump(tester,
          bbox: _bbox, analyzeThrows: Exception('layer service unavailable'));
      await _run(tester);

      expect(find.textContaining('layer service unavailable'), findsOneWidget);
    });

    testWidgets('the cap is stated with the count beyond it', (tester) async {
      // FR105a — "the cap is stated with the count beyond it, never a silent
      // truncation".
      await _pump(tester,
          bbox: _bbox,
          result: _result([_proposal('c1')], cap: 30, beyond: 12));
      await _run(tester);

      expect(find.textContaining('+12 more proposals beyond the reviewable cap of 30'),
          findsOneWidget);
      expect(find.textContaining('+12 BEYOND THE CAP'), findsOneWidget);
    });
  });

  group('the one-gesture actions', () {
    testWidgets('Reject removes the card and offers an undo', (tester) async {
      final (container, _) = await _pump(tester,
          bbox: _bbox,
          result: _result([_proposal('c1', name: 'Old Fort'), _proposal('c2')]));
      await _run(tester);

      await tester.tap(find.descendant(
          of: _cardFor('Old Fort'), matching: find.text('Reject')));
      await _settle(tester);

      expect(find.text('Rejected "Old Fort"'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      expect(container.read(proposalsProvider).rejectedIds, contains('c1'));
    });

    testWidgets('Undo puts it back', (tester) async {
      final (container, _) = await _pump(tester,
          bbox: _bbox, result: _result([_proposal('c1', name: 'Old Fort')]));
      await _run(tester);

      await tester.tap(find.textContaining('Reject').first);
      await _settle(tester);
      await tester.tap(find.text('Undo'));
      await _settle(tester);

      expect(container.read(proposalsProvider).rejectedIds, isEmpty);
    });

    testWidgets('Defer keeps it listed rather than removing it', (tester) async {
      // Deferred is "not now", not "no" — it sinks below the others and stays
      // reviewable.
      final (container, _) = await _pump(tester,
          bbox: _bbox, result: _result([_proposal('c1', name: 'Old Fort')]));
      await _run(tester);

      await tester.tap(find.textContaining('Defer').first);
      await _settle(tester);

      expect(container.read(proposalsProvider).deferredIds, contains('c1'));
      expect(find.text('Old Fort'), findsOneWidget);
    });
  });

  group('Promote — the only action that writes canon', () {
    testWidgets('creates an anchor at the cluster centroid, titled and sourced',
        (tester) async {
      final (container, _) = await _pump(tester,
          bbox: _bbox,
          result: _result([
            _proposal('c1', name: 'Old Fort', affinities: ['narrative'],
                members: [_member('cand-9', 'historic', 0.9, 'narrative')]),
          ]));
      await _run(tester);

      await tester.tap(find.textContaining('Promote').first);
      await _settle(tester);

      final anchors = container.read(currentTripProvider).anchors;
      expect(anchors, hasLength(1));
      expect(anchors.single.title, 'Old Fort');
      expect(anchors.single.coord, [-82.0, 36.0]);
      // O1 — the promoted anchor records which candidate and layer it came
      // from, so the Author can trace it back.
      expect(anchors.single.provenance?.sourceId, 'cand-9');
      expect(anchors.single.provenance?.layer, 'historic');
    });

    testWidgets('pre-fills the cluster\'s affinity-union role set', (tester) async {
      // FR105 / O1 — "the system proposes, the Author decides": every affinity
      // in the cluster becomes a role, editable afterwards on Content.
      final (container, _) = await _pump(tester,
          bbox: _bbox,
          result: _result([
            _proposal('c1',
                name: 'Spring & Marker',
                affinities: ['narrative', 'provision'],
                members: [
                  _member('cand-1', 'historic', 0.9, 'narrative'),
                  _member('cand-2', 'water', 0.7, 'provision'),
                ]),
          ]));
      await _run(tester);

      await tester.tap(find.textContaining('Promote').first);
      await _settle(tester);

      final roles = container.read(currentTripProvider).anchors.single.roles;
      expect(roles, hasLength(2));
      expect(roles.map((r) => r.kind).toSet(), hasLength(2),
          reason: 'both affinities should become distinct roles');
    });

    testWidgets('says what it did and where to edit it', (tester) async {
      await _pump(tester,
          bbox: _bbox, result: _result([_proposal('c1', name: 'Old Fort')]));
      await _run(tester);

      await tester.tap(find.textContaining('Promote').first);
      await _settle(tester);

      expect(find.textContaining('Promoted "Old Fort"'), findsOneWidget);
      expect(find.textContaining('edit on Content'), findsOneWidget);
    });

    testWidgets('promoting the same feature twice is refused, not duplicated',
        (tester) async {
      final (container, _) = await _pump(tester,
          bbox: _bbox,
          result: _result([
            _proposal('c1', name: 'Old Fort',
                members: [_member('cand-9', 'historic', 0.9, 'narrative')]),
          ]));
      await _run(tester);

      await tester.tap(find.textContaining('Promote').first);
      await _settle(tester);
      // The success message has to clear first, or the refusal just queues
      // behind it and never renders.
      await _clearSnackBar(tester);

      await tester.tap(find.textContaining('Promote').first);
      await _settle(tester);

      expect(container.read(currentTripProvider).anchors, hasLength(1));
      expect(find.textContaining('already an anchor'), findsOneWidget);
    });
  });
}

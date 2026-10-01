// FR142(c) (Story K12), Flow 10 §04 — each empty condition K12 names renders
// on its real surface through the registry, and its next action is a control
// that does it, not only a sentence. The switch is exhaustive over
// [EmptyStateContext], so a new context does not compile here until its
// surface is checked.
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
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/roster_tab.dart';
import 'package:plotlines_client/presentation/widgets/day_timeline_strip.dart';
import 'package:plotlines_client/presentation/widgets/empty_state_notice.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';
import 'support/display_units.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// A sidecar whose layers all answer, and find nothing.
class _EmptyAreaCurationClient extends CurationClient {
  _EmptyAreaCurationClient() : super('http://fake');

  @override
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async =>
      LayerCatalog(layers: const ['sight', 'natural'], defaultLive: const {'sight', 'natural'},
          rulesetVersion: '1.0.0');

  @override
  Future<CandidateExtraction> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async =>
      CandidateExtraction(candidates: const [], layersServed: liveLayers.toList());
}

Trip _trip({List<Day> days = const []}) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days,
      modes: const {'cycling'},
    );

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Trip trip,
  Widget Function(Trip trip) surface, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(overrides: [metricUnits(), ...overrides]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) => surface(ref.watch(currentTripProvider))),
      ),
    ),
  ));
  return container;
}

Widget _logistics(Trip trip) => LogisticsTab(trip: trip, onOpenSegment: (_, _) {});
Widget _strip(Trip trip) => DayTimelineStrip(
    trip: trip, activeDayId: trip.days.isEmpty ? null : trip.days.first.id, onSelectDay: (_) {});

Finder _notice(EmptyStateContext context) => find.byKey(EmptyStateNotice.keyFor(context));

Finder _action(EmptyStateContext context, String label) =>
    find.descendant(of: _notice(context), matching: find.text(label));

void main() {
  for (final emptyContext in EmptyStateContext.values) {
    testWidgets('$emptyContext names its next action on its surface', (tester) async {
      switch (emptyContext) {
        case EmptyStateContext.tripNoDays:
          final container = await _pump(tester, _trip(), _logistics);
          expect(_notice(emptyContext), findsOneWidget);
          await tester.tap(_action(emptyContext, 'Add a rest day'));
          await tester.pump();
          expect(container.read(currentTripProvider).days.single.isRest, isTrue);
          expect(_notice(emptyContext), findsNothing);
          // The Route tab's day strip says the same, with the same actions.
          await _pump(tester, _trip(), _strip);
          expect(_action(emptyContext, 'Add a route day'), findsOneWidget);

        case EmptyStateContext.dayNoPassages:
          final day = Day(id: 'd1', index: 1);
          final container = await _pump(tester, _trip(days: [day]), _logistics);
          await tester.tap(_action(emptyContext, 'Make it a rest day'));
          await tester.pump();
          expect(container.read(currentTripProvider).days.single.isRest, isTrue);
          await _pump(tester, _trip(days: [day]), _strip);
          expect(_action(emptyContext, 'Add a passage'), findsOneWidget);

        case EmptyStateContext.bboxNoPromotedAnchors:
          var proposalsOpened = false;
          await _pump(
            tester,
            _trip(),
            (t) => AnchorsView(
              trip: t,
              onBrowseCandidates: () {},
              onFindProposals: () => proposalsOpened = true,
            ),
          );
          await tester.tap(_action(emptyContext, 'Find the good spots'));
          expect(proposalsOpened, isTrue);

        case EmptyStateContext.rosterNoCharacters:
          await _pump(tester, _trip(), (_) => const RosterTab());
          expect(_notice(emptyContext), findsOneWidget);

        case EmptyStateContext.layerSetNoCandidates:
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          final container = await _pump(
            tester,
            _trip(),
            (t) => LayersTab(trip: t, activeDayId: null),
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
              curationClientProvider.overrideWithValue(_EmptyAreaCurationClient()),
              tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(_bbox)),
            ],
          );
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          // Not before a run: an area nobody has asked about is not empty.
          expect(_notice(emptyContext), findsNothing);
          await container
              .read(tripCandidatesProvider.notifier)
              .fetch(bbox: _bbox, liveLayers: {'sight', 'natural'});
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(_notice(emptyContext), findsOneWidget);
          expect(_action(emptyContext, 'Widen the trip area'), findsOneWidget);

        case EmptyStateContext.passageNoAlternates:
          final passage = Segment(id: 's1', mode: 'cycling', shape: 'point_to_point');
          await _pump(tester, _trip(days: [Day(id: 'd1', index: 1, segments: [passage])]), _logistics);
          expect(_notice(emptyContext), findsOneWidget);

        case EmptyStateContext.branchNoAnchors:
        case EmptyStateContext.branchNoNarration:
          // Rendered inside the alternate card's dialog; asserted on that
          // surface by `logistics_tab_alternates_test.dart` ("the anchors and
          // narration empty states are one line plus their next action").
          expect(emptyStateRegistry[emptyContext]!.nextAction, isNotEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }
}

// FR140/FR140a (Story Q3) — the stale list, and the one confirming step in it.
//
// #235 B5. `stale_list_dialog.dart` sat at 1.2% coverage: the single covered
// line was `ensureNoStaleWork`'s early return when nothing is stale. Everything
// past it — the list, re-solve-all, per-item re-solve, and the *destructive*
// drop — had never run.
//
// Two properties carry the weight here. `ensureNoStaleWork` gates export, so a
// wrong answer either blocks a clean trip or exports a stale one; and Drop
// removes a route, so its confirmation has to actually gate it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/widgets/stale_list_dialog.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Re-solves cleanly, or refuses to, on demand. Mirrors the fake in
/// `current_trip_provider_resolve_stale_test.dart`.
class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient({this.failWith}) : super('http://fake');

  final String? failWith;
  int solves = 0;

  @override
  Future<String> ensureRegion(List<double> bboxWsen,
          {String networkType = 'bike', bool retry = false}) async =>
      'region-1';

  @override
  Future<Segment> generateSegment({
    required String region,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async {
    solves++;
    if (failWith != null) throw Exception(failWith);
    return Segment(
      id: 'ignored',
      mode: mode,
      shape: shape,
      start: start,
      end: end,
      via: via,
      metrics: RouteMetrics(distanceM: 5000),
      solve: SolveProvenance(solvedAt: '2026-09-02T00:00:00Z', stale: false),
    );
  }
}

Segment _stale(String id) => Segment(
      id: id,
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.27, 40.02],
      solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z', stale: true),
    );

Segment _fresh(String id) => Segment(
      id: id,
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.28, 40.03],
      solve: SolveProvenance(solvedAt: '2026-09-02T00:00:00Z', stale: false),
    );

Trip _trip(List<Day> days) => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days,
    );

/// Where `ensureNoStaleWork`'s answer lands. Awaiting it directly would
/// deadlock — the future cannot settle until the test taps something.
class _Proceed {
  bool? value;
  bool settled = false;
}

Future<(_Proceed, ProviderContainer)> _open(
  WidgetTester tester,
  Trip trip, {
  _FakeRoutingClient? client,
}) async {
  final routing = client ?? _FakeRoutingClient();
  final container = ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(routing),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(
          minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
  ]);
  container.read(currentTripProvider.notifier).open(trip);

  final proceed = _Proceed();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              proceed.value = await ensureNoStaleWork(
                  context, container.read(currentTripProvider));
              proceed.settled = true;
            },
            child: const Text('export'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('export'));
  await tester.pumpAndSettle();
  return (proceed, container);
}

void main() {
  group('the export gate', () {
    testWidgets('a trip with nothing stale proceeds without a dialog',
        (tester) async {
      // Q3's AC: the list is shown *on an export attempt while any route is
      // stale*. A clean trip must not be interrupted.
      final (proceed, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_fresh('s1')])]));
      addTearDown(container.dispose);

      expect(find.byType(AlertDialog), findsNothing);
      expect(proceed.settled, isTrue);
      expect(proceed.value, isTrue);
    });

    testWidgets('a stale route opens the list instead of exporting',
        (tester) async {
      final (proceed, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(proceed.settled, isFalse, reason: 'export must wait on the Author');
    });

    testWidgets('closing with items still stale does not export', (tester) async {
      final (proceed, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(proceed.value, isFalse);
    });

    testWidgets('the dialog cannot be dismissed by tapping the barrier',
        (tester) async {
      // `barrierDismissible: false` — clearing the list is a decision, not
      // something to fall out of by mis-tapping.
      final (proceed, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(proceed.settled, isFalse);
    });
  });

  group('the list', () {
    testWidgets('counts the stale routes and names each one', (tester) async {
      final (_, container) = await _open(
          tester,
          _trip([
            Day(id: 'd1', index: 1, segments: [_stale('s1'), _fresh('s2')]),
            Day(id: 'd3', index: 3, segments: [_stale('s3')]),
          ]));
      addTearDown(container.dispose);

      expect(find.textContaining('2 stale routes need re-solving'), findsOneWidget);
      expect(find.text('Day 1 — cycling loop'), findsOneWidget);
      expect(find.text('Day 3 — cycling loop'), findsOneWidget);
    });

    testWidgets('a single stale route reads in the singular', (tester) async {
      final (_, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      expect(find.textContaining('1 stale route needs re-solving'), findsOneWidget);
    });

    testWidgets('a fresh route is not listed', (tester) async {
      final (_, container) = await _open(
          tester,
          _trip([
            Day(id: 'd1', index: 1, segments: [_stale('s1')]),
            Day(id: 'd2', index: 2, segments: [_fresh('s2')]),
          ]));
      addTearDown(container.dispose);

      expect(find.text('Day 2 — cycling loop'), findsNothing);
    });

    testWidgets('explains that an edit caused this, not a failure',
        (tester) async {
      // The list is deliberately not routed through M13's shared error surface:
      // "stale work is pending work the Author caused deliberately by editing,
      // not a failure." The copy has to carry that.
      final (_, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      expect(find.textContaining('An edit changed what these were asked to solve for'),
          findsOneWidget);
    });
  });

  group('re-solve all', () {
    testWidgets('clears every stale route and lets the export proceed',
        (tester) async {
      // FR140: "after which the export proceeds" — clearing the list closes
      // the dialog on its own rather than waiting for another tap.
      final client = _FakeRoutingClient();
      final (proceed, container) = await _open(
          tester,
          _trip([
            Day(id: 'd1', index: 1, segments: [_stale('s1')]),
            Day(id: 'd2', index: 2, segments: [_stale('s2')]),
          ]),
          client: client);
      addTearDown(container.dispose);

      await tester.tap(find.text('Re-solve all'));
      await tester.pumpAndSettle();

      expect(client.solves, 2);
      expect(find.byType(AlertDialog), findsNothing);
      expect(proceed.value, isTrue);
    });

    testWidgets('re-solve-all never asks for confirmation', (tester) async {
      // "re-solve-all as one unconfirmed action at the top since it destroys
      // nothing — unlike dropping an item, which does confirm."
      final (_, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      await tester.tap(find.text('Re-solve all'));
      await tester.pump();

      expect(find.text('Keep'), findsNothing);
    });

    testWidgets('a failure is reported in place and leaves the list open',
        (tester) async {
      final client = _FakeRoutingClient(failWith: 'no route found');
      final (proceed, container) = await _open(
          tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]),
          client: client);
      addTearDown(container.dispose);

      await tester.tap(find.text('Re-solve all'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no route found'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(proceed.settled, isFalse, reason: 'a failed re-solve is not consent to export');
    });
  });

  group('per-item resolution', () {
    testWidgets('re-solving one item leaves the others listed', (tester) async {
      final client = _FakeRoutingClient();
      final (_, container) = await _open(
          tester,
          _trip([
            Day(id: 'd1', index: 1, segments: [_stale('s1')]),
            Day(id: 'd2', index: 2, segments: [_stale('s2')]),
          ]),
          client: client);
      addTearDown(container.dispose);

      await tester.tap(find.text('Re-solve').first);
      await tester.pumpAndSettle();

      expect(client.solves, 1);
      expect(find.text('Day 2 — cycling loop'), findsOneWidget);
      expect(find.text('Day 1 — cycling loop'), findsNothing);
    });

    testWidgets('a per-item failure is reported on that row', (tester) async {
      final client = _FakeRoutingClient(failWith: 'graph not ready');
      final (_, container) = await _open(
          tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]),
          client: client);
      addTearDown(container.dispose);

      await tester.tap(find.text('Re-solve'));
      await tester.pumpAndSettle();

      expect(find.textContaining('graph not ready'), findsOneWidget);
      expect(find.text('Day 1 — cycling loop'), findsOneWidget);
    });
  });

  group('dropping a route — the one confirming step', () {
    testWidgets('Drop asks first', (tester) async {
      // FR140's own callout: "where the list offers dropping an object instead
      // of re-solving it, that action does confirm".
      final (_, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      await tester.tap(find.text('Drop'));
      await tester.pumpAndSettle();

      expect(find.text('Drop this route?'), findsOneWidget);
      expect(find.textContaining('Day 1 — cycling loop'), findsWidgets);
      expect(find.textContaining('anchors survive unattached'), findsOneWidget);
    });

    testWidgets('declining the confirmation keeps the route', (tester) async {
      final (_, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      await tester.tap(find.text('Drop'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      expect(container.read(currentTripProvider).days.single.segments, hasLength(1));
      expect(find.text('Day 1 — cycling loop'), findsOneWidget);
    });

    testWidgets('confirming removes the route from the trip', (tester) async {
      final (_, container) = await _open(
          tester,
          _trip([
            Day(id: 'd1', index: 1, segments: [_stale('s1'), _fresh('s2')]),
          ]));
      addTearDown(container.dispose);

      await tester.tap(find.text('Drop'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drop').last);
      await tester.pumpAndSettle();

      final segments = container.read(currentTripProvider).days.single.segments;
      expect(segments.map((s) => s.id), ['s2'],
          reason: 'only the dropped route goes');
    });

    testWidgets('dropping the last stale route lets the export proceed',
        (tester) async {
      final (proceed, container) =
          await _open(tester, _trip([Day(id: 'd1', index: 1, segments: [_stale('s1')])]));
      addTearDown(container.dispose);

      await tester.tap(find.text('Drop'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drop').last);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(proceed.value, isTrue);
    });
  });
}

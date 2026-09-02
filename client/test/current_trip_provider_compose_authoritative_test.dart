// Issue #212 — `/days/compose` and `/trips/split` are implemented but the
// client never called them; the day-timeline's transition-gap warnings and
// day-limit breaches came only from the interactive-editing mirrors
// (`resequencePassages`, `CurrentTripNotifier.rollUpTrip`), never from the
// authoritative `compose_day`/`split_trip`. `composeAuthoritative` is the fix:
// it calls both and merges only their derived fields onto the local trip,
// since neither round-trips a day/trip's authored fields.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';

/// Mirrors what the real endpoints actually do (`compose.py`): `composeDay`
/// hands back a *fresh* `Day` (a different id, none of the local day's
/// authored fields) carrying only `transitions`/`metrics`; `assembleTrip`
/// mutates the `Day`s it was handed in place (ids and authored fields
/// survive) and sets each one's `metrics.limitBreaches`, wrapped in a `Trip`
/// that otherwise carries none of the real trip's identity.
class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient() : super('http://fake');

  final composeDayCalls = <String>[]; // day kind:index composed, in order
  var assembleTripCallCount = 0;
  RoutingException? composeDayFailure;

  // issue #214 — the last two args are the compose spine + A0a readout target;
  // recorded so a test can assert what `composeAuthoritative` resolved.
  final composeDayAnchors = <List<String>>[];
  final composeDayTargets = <double?>[];
  ComposeItinerary? composeItinerary;

  @override
  Future<ComposedDay> composeDay({
    required List<Segment> segments,
    List<Transition> transitions = const [],
    int index = 1,
    String kind = 'route',
    List<Anchor> anchors = const [],
    double? targetM,
  }) async {
    if (composeDayFailure != null) throw composeDayFailure!;
    composeDayCalls.add('$kind:$index');
    composeDayAnchors.add([for (final a in anchors) a.id]);
    composeDayTargets.add(targetM);
    return ComposedDay(
      day: Day(
        id: 'server-assigned-$index', // compose_day never learns the real id.
        index: index,
        kind: kind,
        segments: segments,
        transitions: [
          for (final t in transitions) t.copyWith(gapM: 9999, gapWarning: true),
        ],
        metrics: RollUp(total: RouteMetrics(distanceM: 12345)),
      ),
      itinerary: anchors.length >= 2 ? composeItinerary : null,
    );
  }

  @override
  Future<AssembledTrip> assembleTrip({
    required List<Day> days,
    required String title,
    Map<String, DayLimit>? limits,
    WeightProfile? defaultWeights,
    // FR16 time-model inputs (issue #213). `composeAuthoritative` doesn't pass
    // them, so the fake only has to match the signature to be a valid override.
    String? activeSegmentId,
    Map<String, double>? speeds,
    Map<String, double>? dayHoldS,
    Map<String, String>? dayStartAt,
    String? tripStartAt,
  }) async {
    assembleTripCallCount++;
    // split_trip mutates in place: same ids, `metrics.limitBreaches` added.
    final assembled = [
      for (final d in days)
        d.copyWith(
          metrics: RollUp(
            total: d.metrics?.total,
            limitBreaches: [
              LimitBreach(
                mode: 'cycling',
                bound: 'max',
                limitM: 1000,
                realisedM: d.metrics?.total?.distanceM ?? 0,
                dayId: d.id,
              ),
            ],
          ),
        ),
    ];
    return AssembledTrip(
      trip: Trip(
        id: 'ignored', // split_trip never learns the real trip id either.
        title: title,
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: assembled,
        metrics: RollUp(total: RouteMetrics(distanceM: 24690)),
      ),
      hazardRollup: const HazardRollup.empty(),
    );
  }
}

ProviderContainer _container(_FakeRoutingClient client) =>
    ProviderContainer(overrides: [routingClientProvider.overrideWithValue(client)]);

Trip _tripWith(List<Day> days) => Trip(
      id: 't1',
      title: 'A trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: days,
      anchors: [
        Anchor(
          id: 'a1',
          title: 'Overlook',
          coord: const [-105.3, 40.0],
          roles: [Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.alwaysVisible)],
        ),
      ],
    );

/// A three-place compose spine: `start` + one `via` + `end`, each coord sitting
/// exactly on a promoted anchor (the spine editor sets `via` straight from
/// anchor coords, so `composeAuthoritative` resolves them by exact match).
Trip _composeTripWith(Segment spine) => Trip(
      id: 't1',
      title: 'A trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1, segments: [spine])],
      anchors: [
        for (final (id, coord) in const [
          ('anc-a', [-105.30, 40.0]),
          ('anc-b', [-105.25, 40.0]),
          ('anc-c', [-105.20, 40.0]),
        ])
          Anchor(
            id: id,
            title: id,
            coord: coord,
            roles: [Role(id: 'r-$id', kind: RoleKind.narrative, reveal: RevealPolicy.alwaysVisible)],
          ),
      ],
    );

void main() {
  test('a compose-mode day resolves its spine anchors and captures the itinerary '
      '(issue #214)', () async {
    final client = _FakeRoutingClient()
      ..composeItinerary = ComposeItinerary(
        planningMode: 'compose',
        spine: const ['anc-a', 'anc-b', 'anc-c'],
        stops: const [],
        legs: const [],
        distance: ComposeDistanceOutcome(realisedM: 8520),
      );
    final container = _container(client);
    addTearDown(container.dispose);

    final spine = Segment(
      id: 's1',
      mode: 'hiking',
      shape: 'point_to_point',
      start: const [-105.30, 40.0],
      via: const [[-105.25, 40.0]],
      end: const [-105.20, 40.0],
      targetDistance: TargetDistance(valueM: 10000, minM: 9000, maxM: 11000),
    );
    container.read(currentTripProvider.notifier).open(_composeTripWith(spine));
    container.read(dayPlanningModeProvider('d1').notifier).state = PlanningMode.compose;

    await container.read(currentTripProvider.notifier).composeAuthoritative();

    // the spine's [start, ...via, end] coords each resolved to their anchor
    expect(client.composeDayAnchors.single, ['anc-a', 'anc-b', 'anc-c']);
    // "what the Author had in mind" rode along as a readout target (never a solve
    // constraint) so A0a's DistanceOutcome can quantify the miss
    expect(client.composeDayTargets.single, 10000);
    // and the returned itinerary landed on the ephemeral provider
    expect(container.read(composeItineraryProvider('d1'))!.distance.realisedM, 8520);
  });

  test('an explore-mode day sends no spine and clears any stale itinerary', () async {
    final client = _FakeRoutingClient();
    final container = _container(client);
    addTearDown(container.dispose);

    final spine = Segment(
      id: 's1',
      mode: 'hiking',
      shape: 'point_to_point',
      start: const [-105.30, 40.0],
      via: const [[-105.25, 40.0]],
      end: const [-105.20, 40.0],
    );
    container.read(currentTripProvider.notifier).open(_composeTripWith(spine));
    // left at the default (explore)

    await container.read(currentTripProvider.notifier).composeAuthoritative();

    expect(client.composeDayAnchors.single, isEmpty);
    expect(client.composeDayTargets.single, isNull);
    expect(container.read(composeItineraryProvider('d1')), isNull);
  });

  test('composeAuthoritative merges compose_day/split_trip\'s derived fields, '
      'preserving every authored field they never round-trip', () async {
    final client = _FakeRoutingClient();
    final container = _container(client);
    addTearDown(container.dispose);

    final day1 = Day(id: 'd1', index: 1, title: 'Ridge day', segments: [
      Segment(id: 's1', mode: 'cycling', shape: 'point_to_point', start: const [0, 0], end: const [1, 1]),
      Segment(id: 's2', mode: 'cycling', shape: 'point_to_point', start: const [1, 1], end: const [2, 2]),
    ], transitions: [
      Transition(id: 'tr1', fromSegmentId: 's1', toSegmentId: 's2'),
    ]);
    final restDay = Day(id: 'd2', index: 2, kind: 'rest');
    container.read(currentTripProvider.notifier).open(_tripWith([day1, restDay]));

    await container.read(currentTripProvider.notifier).composeAuthoritative();

    // The rest day (no segments) never goes through composeDay — nothing
    // for `compose_day` to measure, and it would 422 on a rest day besides.
    expect(client.composeDayCalls, ['route:1']);
    expect(client.assembleTripCallCount, 1);

    final trip = container.read(currentTripProvider);
    // Trip identity that neither endpoint round-trips survives untouched.
    expect(trip.id, 't1');
    expect(trip.title, 'A trip');
    expect(trip.anchors.single.title, 'Overlook');
    // Trip-wide metrics come from split_trip's roll-up.
    expect(trip.metrics?.total?.distanceM, 24690);

    final composedDay1 = trip.days.firstWhere((d) => d.index == 1);
    // The real day id survives even though compose_day's response carried
    // a server-assigned one, and so does authored content compose_day never
    // saw.
    expect(composedDay1.id, 'd1');
    expect(composedDay1.title, 'Ridge day');
    expect(composedDay1.segments.map((s) => s.id), ['s1', 's2']);
    // The authoritative gap warning made it onto the transition.
    expect(composedDay1.transitions.single.gapWarning, isTrue);
    expect(composedDay1.transitions.single.gapM, 9999);
    // split_trip's limit breach made it onto the day.
    expect(composedDay1.metrics?.limitBreaches, hasLength(1));
    expect(composedDay1.metrics!.limitBreaches.single.dayId, 'd1');

    final composedRestDay = trip.days.firstWhere((d) => d.index == 2);
    expect(composedRestDay.id, 'd2');
    expect(composedRestDay.kind, 'rest');
  });

  test('TripPersistence.save runs composeAuthoritative but a sidecar failure '
      'never blocks the local save (FR65 — offline is quiet)', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final client = _FakeRoutingClient()
      ..composeDayFailure = RoutingException(500, '{"detail": "sidecar unreachable"}');
    final container = ProviderContainer(overrides: [
      routingClientProvider.overrideWithValue(client),
      appDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);

    final day = Day(id: 'd1', index: 1, segments: [
      Segment(id: 's1', mode: 'cycling', shape: 'point_to_point', start: const [0, 0], end: const [1, 1]),
    ]);
    container.read(currentTripProvider.notifier).open(_tripWith([day]));
    final tripId = container.read(currentTripProvider).id;

    // Must not throw even though composeDay (and so composeAuthoritative)
    // fails outright.
    await container.read(tripPersistenceProvider).save();

    final row = await db.loadTrip(tripId);
    expect(row, isNotNull);
  });
}

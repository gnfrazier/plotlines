// FR6 (Story A5) — "Add band" opens on the range this region can actually
// deliver, probed from the graph (SPIKE-03: fixed defaults were feasible
// 22.2% of the time, envelope-derived 100%), not a blank pair the Author
// has to guess at. `routing_client.dart`'s `envelope()` already existed
// (A5/A8's `/segments/envelope`) but nothing called it — this is that
// wiring, plus proof `salience` (this story's new bandable attribute) is
// now offered by "Add band" too.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Stands in for a real `/segments/envelope` round trip — `RoutingClient`
/// talks HTTP directly rather than through an injectable client, so the one
/// seam available for a widget test is subclassing and overriding the two
/// methods `_addBand` actually calls.
class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient({this.envelopeResult = const {}}) : super('http://fake');

  final Map<String, List<double>> envelopeResult;
  int envelopeCalls = 0;
  double? lastTargetM;

  @override
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike'}) async =>
      'region-1';

  @override
  Future<Map<String, List<double>>> envelope({
    required String region,
    required Coord start,
    required double targetM,
    List<Coord> via = const [],
  }) async {
    envelopeCalls++;
    lastTargetM = targetM;
    return envelopeResult;
  }
}

Segment _loopSegment({double targetM = 20000}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.27, 40.02],
      targetDistance: TargetDistance(valueM: targetM),
    );

Segment _pointToPointSegment() => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
    );

Trip _trip(Segment segment) {
  final day = Day(id: 'day-1', index: 1, segments: [segment]);
  return Trip(
    id: 'trip-1',
    title: 'Test trip',
    createdAt: '2026-08-25T00:00:00Z',
    updatedAt: '2026-08-25T00:00:00Z',
    days: [day],
  );
}

Future<_FakeRoutingClient> _pump(
  WidgetTester tester,
  Segment segment, {
  Map<String, List<double>> envelopeResult = const {},
  bool withBbox = true,
}) async {
  final client = _FakeRoutingClient(envelopeResult: envelopeResult);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segment))),
        routingClientProvider.overrideWithValue(client),
        if (withBbox)
          tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
            ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
      ],
      child: MaterialApp(
        home: Scaffold(body: WeightsRail(dayId: 'day-1', segment: segment)),
      ),
    ),
  );
  await tester.pump();
  return client;
}

/// The rail's bottom section can outgrow the fixed-height wireframe budget,
/// so its middle scrolls (same as `weights_rail_planning_mode_test.dart`'s
/// `_tap` helper) — this scrolls "Add band" into view before tapping it.
Future<void> _tapAddBand(WidgetTester tester) async {
  final finder = find.text('Add band');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('adding a band on a loop with a target distance probes the '
      'envelope and opens on the returned range', (tester) async {
    final client = await _pump(
      tester,
      _loopSegment(targetM: 15000),
      envelopeResult: {'distance_m': [12000.0, 15000.0], 'climb_m': [50.0, 200.0]},
    );

    await _tapAddBand(tester);

    expect(client.envelopeCalls, 1);
    expect(client.lastTargetM, 15000.0);
    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final band = container.read(currentTripProvider).days.single.segments.single.bands.single;
    expect(band.attribute, 'distance_m');
    expect(band.min, 12000.0);
    expect(band.max, 15000.0);
    expect(band.source, 'envelope');
  });

  testWidgets('salience is offered once every other attribute already has a band',
      (tester) async {
    final segment = _loopSegment().copyWith(bands: [
      for (final a in const ['distance_m', 'climb_m', 'descent_m', 'traffic', 'unpaved_frac', 'scenic_frac'])
        Band(attribute: a, min: 0.0, max: 1.0),
    ]);
    await _pump(tester, segment, envelopeResult: {'salience': [0.1, 0.4]});

    await _tapAddBand(tester);

    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final bands = container.read(currentTripProvider).days.single.segments.single.bands;
    final added = bands.last;
    expect(added.attribute, 'salience');
    expect(added.min, 0.1);
    expect(added.max, 0.4);
  });

  testWidgets('a point_to_point segment falls back to a blank band without probing '
      '(the envelope only knows how to search loops)', (tester) async {
    final client = await _pump(tester, _pointToPointSegment());

    await _tapAddBand(tester);

    expect(client.envelopeCalls, 0);
    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final band = container.read(currentTripProvider).days.single.segments.single.bands.single;
    expect(band.min, isNull);
    expect(band.max, isNull);
    expect(band.source, isNull);
  });

  testWidgets('a loop with no target distance yet falls back to a blank band',
      (tester) async {
    final segmentNoTarget = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.27, 40.02],
    );
    final client = await _pump(tester, segmentNoTarget);

    await _tapAddBand(tester);

    expect(client.envelopeCalls, 0);
  });

  testWidgets('an attribute the probe has no range for still gets a band, blank',
      (tester) async {
    await _pump(tester, _loopSegment(), envelopeResult: const {}); // empty envelope

    await _tapAddBand(tester);

    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final band = container.read(currentTripProvider).days.single.segments.single.bands.single;
    expect(band.min, isNull);
    expect(band.max, isNull);
  });
}

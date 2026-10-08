// Issue #656 — inside the trip shell, a region still building used to read
// as an error: the rail's Generate / Regenerate stayed enabled, and the
// sidecar's `503 routing not ready for region …` came back as the red
// ConflictBanner. Waits are not failures (#522, #573): the rail now reads the
// same routing capability New Route reads, shows the quiet wait notice above
// the controls it disables, and a 503 that still arrives reads as the wait.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/widgets/error_states.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'support/display_units.dart';

Segment _segment({List<Band> bands = const [], bool solved = true}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-79.50, 36.10],
      end: const [-79.40, 36.15],
      bands: bands,
      geometry: solved
          ? LineString(coordinates: const [[-79.50, 36.10], [-79.40, 36.15]])
          : null,
      metrics: solved ? RouteMetrics(distanceM: 9000) : null,
    );

class _NotReadyRoutingClient extends RoutingClient {
  _NotReadyRoutingClient() : super('http://fake');

  @override
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike', bool retry = false}) async =>
      'region-1';

  @override
  Future<Segment> generateSegment({
    required String region,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String? discipline,
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async =>
      throw RoutingException(
          503, jsonEncode({'detail': "routing not ready for region 'region-1': building graph"}));
}

Future<void> _pump(WidgetTester tester, Segment segment, CapabilityStatus routing) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final trip = Trip(
    id: 't',
    title: 'Greensboro',
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    days: [Day(id: 'd1', index: 1, segments: [segment])],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      metricUnits(),
      tripRoutingCapabilityProvider.overrideWithValue(routing),
      routingClientProvider.overrideWithValue(_NotReadyRoutingClient()),
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
        ..set(const TripBbox(minLat: 35.9, minLon: -79.6, maxLat: 36.3, maxLon: -79.2))),
      currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(trip)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => WeightsRail(
            dayId: 'd1',
            segment: ref.watch(currentTripProvider).days.single.segments.single,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

PlotButton _button(WidgetTester tester, String label) =>
    tester.widget<PlotButton>(find.widgetWithText(PlotButton, label));

String _tooltipOf(WidgetTester tester, String label) => tester
    .widget<Tooltip>(find.ancestor(of: find.widgetWithText(PlotButton, label), matching: find.byType(Tooltip)))
    .message!;

void main() {
  testWidgets('a region still building is the quiet wait, and the routing controls wait with it',
      (tester) async {
    await _pump(
      tester,
      _segment(bands: [Band(attribute: 'climb_m', min: 100)]),
      const CapabilityStatus(ready: false, reason: 'building the routing graph', progress: 0.4),
    );

    expect(find.byKey(const ValueKey('rail-routing-capability')), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    expect(find.byType(ConflictBanner), findsNothing);
    expect(find.text('Routing is unavailable'), findsNothing);
    expect(_button(tester, 'Regenerate').onPressed, isNull);
    expect(_button(tester, 'Diagnose').onPressed, isNull);
    expect(_tooltipOf(tester, 'Diagnose'), 'Routing isn\'t ready for this area yet');
  });

  testWidgets('a region that failed shows the failure card with its Try again', (tester) async {
    await _pump(
      tester,
      _segment(),
      const CapabilityStatus(ready: false, reason: 'failed:the trip area could not be prepared for routing'),
    );

    expect(find.text('Routing is unavailable'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(_button(tester, 'Regenerate').onPressed, isNull);
  });

  testWidgets('a 503 "routing not ready" that still arrives reads as the wait, not an error',
      (tester) async {
    await _pump(tester, _segment(), const CapabilityStatus(ready: true));
    expect(find.byKey(const ValueKey('rail-routing-capability')), findsNothing);

    await tester.tap(find.widgetWithText(PlotButton, 'Regenerate'));
    await tester.pumpAndSettle();

    expect(find.byType(ConflictBanner), findsNothing);
    expect(find.byKey(const ValueKey('rail-routing-wait')), findsOneWidget);
    expect(find.textContaining('still getting this area ready'), findsOneWidget);
  });

  testWidgets('F21 — Diagnose with a band but no route yet says to generate first', (tester) async {
    await _pump(
      tester,
      _segment(bands: [Band(attribute: 'climb_m', min: 100)], solved: false),
      const CapabilityStatus(ready: true),
    );

    expect(_button(tester, 'Diagnose').onPressed, isNull);
    expect(_tooltipOf(tester, 'Diagnose'), 'Generate the route first');
  });
}

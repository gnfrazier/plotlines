// M13 / FR145 (review fix) — the Export tab's failure dialog used to show
// `'$e'`: a `FileSystemException`'s path and errno, a `MissingPluginException`'s
// channel name, or `RoutingException(500): <body>`, straight to the Author.
// What reaches the surface is a finished sentence, never an exception.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// The cue-sheet option ensures a region before anything is written; this one
/// fails the way an unhandled sidecar error does — a raw body, not a sentence.
class _FailingRoutingClient extends RoutingClient {
  _FailingRoutingClient() : super('http://fake');

  @override
  Future<String> ensureRegion(List<double> bboxWsen,
          {String networkType = 'bike', bool retry = false}) async =>
      throw RoutingException(500, 'Traceback (most recent call last): KeyError');
}

void main() {
  test('a sidecar reason that reads as a sentence passes through', () {
    expect(exportFailureReason(RoutingException(409, '{"detail": "the region is still loading"}')),
        'the region is still loading');
  });

  test('a raw sidecar body, a file error and anything else become fixed phrases', () {
    for (final e in <Object>[
      RoutingException(500, 'Traceback (most recent call last): ...'),
      const FileSystemException('Cannot open file', '/root/x.gpx', OSError('Permission denied', 13)),
      StateError('boom'),
    ]) {
      final reason = exportFailureReason(e);
      expect(looksLikeRawDiagnostic(reason), isFalse, reason: reason);
      expect(reason, isNot(contains('/root')));
    }
  });

  testWidgets('a failed export shows a sentence, not the exception', (tester) async {
    final container = ProviderContainer(overrides: [
      routingClientProvider.overrideWithValue(_FailingRoutingClient()),
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
        ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
    ]);
    addTearDown(container.dispose);
    container.read(currentTripProvider.notifier).open(Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [
            Day(id: 'd1', index: 1, segments: [
              Segment(id: 's1', mode: 'cycling', shape: 'point_to_point',
                  metrics: RouteMetrics(distanceM: 12000)),
            ]),
          ],
        ));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ExportTab(trip: ref.watch(currentTripProvider)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final cues =
        find.ancestor(of: find.text('Cue sheet (turn points)'), matching: find.byType(Row)).first;
    await tester.ensureVisible(cues);
    await tester.tap(find.descendant(of: cues, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    final export = find.text('Export GPX file');
    await tester.ensureVisible(export);
    await tester.tap(export);
    await tester.pumpAndSettle();

    expect(find.text('Export didn\'t finish'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('Something went wrong while writing the export.'), findsOneWidget);
  });
}

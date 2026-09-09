// Issue #320 — the Route tab's map markers.
//
// Before this, `route_tab.dart` concatenated every segment's start then every
// segment's end into one list and `tap_to_pick_map.dart` picked the marker
// from a point's *index*: index 0 → waypoint, last index → regroup (a
// concentric "target" ring), everything between → the narrative `plot`
// marker. On a two-day trip the day-2 start landed in the middle and drew as
// `plot`; a one-point route was both index 0 and the last index at once.
//
// The fix draws role from role: `routeTabMarkerPoints` tags each endpoint,
// and `TapToPickMap` renders one `NodeMarker` per typed point with that tag.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/route_tab.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// The map layer leaves a ticker a single `pump()` does not settle — the same
/// short-pump loop the other map-bearing screen tests use.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Trip _twoDayTrip() => Trip(
      id: 't1',
      title: 'Two-day trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [
        Day(id: 'day-1', index: 1, segments: [
          Segment(
            id: 'seg-1',
            mode: 'cycling',
            shape: 'point_to_point',
            start: const [-105.000, 40.000],
            end: const [-105.004, 40.004],
          ),
        ]),
        Day(id: 'day-2', index: 2, segments: [
          Segment(
            id: 'seg-2',
            mode: 'cycling',
            shape: 'point_to_point',
            start: const [-105.006, 40.006],
            end: const [-105.010, 40.010],
          ),
        ]),
      ],
    );

void main() {
  group('routeTabMarkerPoints', () {
    test('tags every day\'s endpoints by role, not by list position', () {
      final points = routeTabMarkerPoints(_twoDayTrip());

      expect(points.map((p) => p.role).toList(), [
        NodeMarkerType.start, // day 1 start
        NodeMarkerType.finish, // day 1 end
        NodeMarkerType.start, // day 2 start — was `plot` under index logic
        NodeMarkerType.finish, // day 2 end — was `regroup`/target under it
      ]);
      expect(
        points.where((p) => p.role == NodeMarkerType.plot),
        isEmpty,
        reason: 'no endpoint should inherit the narrative marker',
      );
    });

    test('the day-2 start is a start, not the concatenated-list middle', () {
      final points = routeTabMarkerPoints(_twoDayTrip());
      final daytwoStart =
          points.firstWhere((p) => p.coord[0] == -105.006 && p.coord[1] == 40.006);
      expect(daytwoStart.role, NodeMarkerType.start);
    });

    test('a lone start is a start and nothing else', () {
      final trip = Trip(
        id: 't2',
        title: 'One point',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'day-1', index: 1, segments: [
            Segment(
              id: 'seg-1',
              mode: 'hiking',
              shape: 'out_and_back',
              start: const [-105.0, 40.0],
            ),
          ]),
        ],
      );
      final points = routeTabMarkerPoints(trip);
      expect(points, hasLength(1));
      expect(points.single.role, NodeMarkerType.start);
    });
  });

  testWidgets('TapToPickMap renders two starts and two finishes for a two-day trip',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TapToPickMap(
              points: routeTabMarkerPoints(_twoDayTrip()),
              center: const [-105.005, 40.005],
              initialZoom: 12,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    final markers =
        tester.widgetList<NodeMarker>(find.byType(NodeMarker)).map((m) => m.type).toList();
    expect(markers.where((t) => t == NodeMarkerType.start), hasLength(2));
    expect(markers.where((t) => t == NodeMarkerType.finish), hasLength(2));
    expect(markers, isNot(contains(NodeMarkerType.plot)));
    expect(markers, isNot(contains(NodeMarkerType.regroup)));
  });
}

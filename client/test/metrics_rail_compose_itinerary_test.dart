// E3 / FR39 / FR117 / FR118 (issue #214) — `metrics_rail.dart` (the Route tab's
// right rail) gains a COMPOSE ITINERARY section: the ordered promoted places
// with the passages between them and the day's length as a reported outcome
// (A0a — never a constraint, never a conflict). It renders only for a
// compose-mode day whose spine resolved; explore-mode days are unaffected.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart';

Map<String, dynamic> _response({double? targetM}) => {
      'itinerary': {
        'planning_mode': 'compose',
        'spine': ['a1', 'a2', 'a3'],
        'stops': [
          {
            'anchor_id': 'a1',
            'order': 0,
            'title': 'Trailhead',
            'coord': [-105.3, 40.0],
            'roles': ['provision'],
            'arc_stages': <dynamic>[],
            'hazard': false,
            'distance_along_m': 0.0,
            'has_unrevealed_narrative': false,
          },
          {
            'anchor_id': 'a2',
            'order': 1,
            'title': 'Old mine',
            'coord': [-105.25, 40.0],
            'roles': ['narrative'],
            'arc_stages': ['rising'],
            'hazard': true,
            'distance_along_m': 4260.0,
            'has_unrevealed_narrative': true,
          },
          {
            'anchor_id': 'a3',
            'order': 2,
            'title': 'Summit',
            'coord': [-105.2, 40.0],
            'roles': ['narrative'],
            'arc_stages': ['climax'],
            'hazard': false,
            'distance_along_m': 8520.0,
            'has_unrevealed_narrative': false,
          },
        ],
        'legs': [
          for (var i = 0; i < 2; i++)
            {
              'order': i,
              'segment_id': 'seg-$i',
              'mode': 'hiking',
              'distance_m': 4260.0,
              'arc_stage': null,
              'planning_mode': 'compose',
              'hazards': null,
            },
        ],
        'distance': {
          'planning_mode': 'compose',
          'realised_m': 8520.0,
          'target_m': targetM,
          'deviation_m': targetM == null ? null : 8520.0 - targetM,
          'deviation_frac': null,
          'dispositions':
              targetM == null ? ['accept'] : ['drop', 'defer', 'split', 'accept'],
          'is_conflict': false,
          'is_error': false,
        },
      },
      'recap': <dynamic>[],
      'cues': <dynamic>[],
    };

Future<void> _pump(WidgetTester tester, {ComposeItinerary? itinerary}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MetricsRail(
        trip: Trip(
          id: 'trip-1',
          title: 'Test trip',
          createdAt: '2026-08-25T00:00:00Z',
          updatedAt: '2026-08-25T00:00:00Z',
          days: [Day(id: 'd1', index: 1, segments: const [])],
        ),
        selectedSegment: null,
        elevationCapability: const CapabilityStatus(ready: true),
        composeItinerary: itinerary,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('no compose itinerary → no COMPOSE ITINERARY section', (tester) async {
    await _pump(tester);
    expect(find.text('COMPOSE ITINERARY'), findsNothing);
  });

  testWidgets('the section leads with the places and reports the day length', (tester) async {
    await _pump(tester, itinerary: ComposeItinerary.fromResponse(_response()));

    expect(find.text('COMPOSE ITINERARY'), findsOneWidget);
    expect(find.text('DAY DISTANCE'), findsOneWidget);
    expect(find.text('8.5 km'), findsWidgets);
    // every promoted place shows, in spine order
    expect(find.text('Trailhead'), findsOneWidget);
    expect(find.text('Old mine'), findsOneWidget);
    expect(find.text('Summit'), findsOneWidget);
    // pure compose: no "you had in mind" deviation line
    expect(find.textContaining('you had in mind'), findsNothing);
  });

  testWidgets('a target the Author had in mind is reported as an outcome, not a conflict',
      (tester) async {
    await _pump(tester,
        itinerary: ComposeItinerary.fromResponse(_response(targetM: 10000.0)));

    expect(find.textContaining('under the 10.0 km you had in mind'), findsOneWidget);
    expect(find.textContaining('Options: drop · defer · split · accept'), findsOneWidget);
  });
}

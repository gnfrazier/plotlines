// FR9 (Story A6) — the rail surfaces a band violation right where it
// happened: the offending `BandRow` names how far it missed by, and an
// aggregate `ConflictBanner` sits above "Add band." Both render straight off
// `Segment.violations`, synchronous with the solve that produced them
// (`current_trip_provider_band_violations_test.dart` covers how that field
// gets populated) — no "Diagnose" round trip needed just to see them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _segment({required List<Band> bands, required List<Violation> violations}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      bands: bands,
      violations: violations,
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

Future<void> _pump(WidgetTester tester, Segment segment) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segment))),
      ],
      child: MaterialApp(
        home: Scaffold(body: WeightsRail(dayId: 'day-1', segment: segment)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a violated band names how far it missed by, right on its own row',
      (tester) async {
    final segment = _segment(
      bands: [Band(attribute: 'climb_m', min: 280)],
      violations: [Violation(attribute: 'climb_m', realised: 210, shortfall: -70)],
    );
    await _pump(tester, segment);

    expect(find.textContaining('Missed by 70 m'), findsOneWidget);
    // Both the per-row flag and the aggregate ConflictBanner name the miss.
    expect(find.textContaining('realized 210 m'), findsNWidgets(2));
  });

  testWidgets('a satisfied band shows no violation text', (tester) async {
    final segment = _segment(
      bands: [Band(attribute: 'climb_m', min: 280)],
      violations: const [],
    );
    await _pump(tester, segment);

    expect(find.textContaining('Missed by'), findsNothing);
    expect(find.text('No route satisfies every band'), findsNothing);
  });

  testWidgets('an aggregate banner appears above "Add band" whenever any band is violated',
      (tester) async {
    final segment = _segment(
      bands: [Band(attribute: 'climb_m', min: 280), Band(attribute: 'traffic', max: 0.14)],
      violations: [
        Violation(attribute: 'climb_m', realised: 210, shortfall: -70),
      ],
    );
    await _pump(tester, segment);

    expect(find.text('No route satisfies every band'), findsOneWidget);
    // Names the specific missed band (FR9's AC), not a generic message.
    expect(find.textContaining('climb_m'), findsWidgets);
  });
}

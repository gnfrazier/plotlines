// Issue #312 — the display-unit preference (K5 / FR79) was honoured on
// exactly one surface (the New route target-distance field) and ignored
// everywhere else. These pin the two acceptance clauses that don't already
// have a home in a per-surface test file:
//
//  * `MetricsRail` — the Route tab's right rail — renders trip / by-day /
//    by-mode distance and total climb in the Author's units.
//  * flipping the unit never changes the persisted trip payload: display is
//    a render transform, SI metres remain the stored form (ARCH D49).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'support/display_units.dart';

Trip _trip() => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [
        Day(
          id: 'd1',
          index: 1,
          limits: {'cycling': DayLimit(minM: 20000, maxM: 90000)},
          segments: [
            Segment(
              id: 's1',
              mode: 'cycling',
              shape: 'point_to_point',
              metrics: RouteMetrics(distanceM: 42000, climbM: 640),
            ),
          ],
        ),
      ],
    );

Future<void> _pumpMetrics(WidgetTester tester, {required bool imperial}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MetricsRail(
        trip: _trip(),
        selectedSegment: null,
        elevationCapability: const CapabilityStatus(ready: true),
        displayFormat: imperial
            ? const DisplayFormat(useMiles: true)
            : const DisplayFormat(),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('MetricsRail follows the display-unit preference (#312)', () {
    testWidgets('metric renders km and metres', (tester) async {
      await _pumpMetrics(tester, imperial: false);

      expect(find.text('42.0 km'), findsWidgets); // trip + by-day + by-mode
      expect(find.text('↑ 640 m'), findsOneWidget);
    });

    testWidgets('imperial renders miles and feet', (tester) async {
      await _pumpMetrics(tester, imperial: true);

      expect(find.text('26.1 mi'), findsWidgets); // 42000 m
      expect(find.text('↑ 2100 ft'), findsOneWidget); // 640 m -> 2099.7 -> 2100
      expect(find.textContaining('km'), findsNothing);
    });
  });

  testWidgets('rendering a surface under either unit leaves the payload untouched',
      (tester) async {
    final metricPayload = jsonEncode(_trip().toJson());

    Future<String> payloadAfterRendering(Override unit) async {
      final container = ProviderContainer(overrides: [unit]);
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip());
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => LogisticsTab(
                trip: ref.watch(currentTripProvider),
                onOpenSegment: (_, _) {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return jsonEncode(container.read(currentTripProvider).toJson());
    }

    expect(await payloadAfterRendering(metricUnits()), equals(metricPayload));
    expect(await payloadAfterRendering(imperialUnits()), equals(metricPayload));
  });
}

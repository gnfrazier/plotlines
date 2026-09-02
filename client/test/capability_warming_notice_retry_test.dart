// issue #229 — a settled Overpass failure is retryable from the routing
// controls without the Author redrawing the trip area. `CapabilityWarmingNotice`
// grows a "Try again" affordance, but only once the capability has settled
// failed and only when a callback is wired.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/presentation/widgets/error_states.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

Widget _host(Widget child) => MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('a settled failure shows "Try again" and calls onRetry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(_host(CapabilityWarmingNotice(
      capabilityLabel: 'Routing',
      status: const CapabilityStatus(
        ready: false,
        reason: 'failed:Couldn\'t reach the map-data service to prepare '
            'routing for this area.',
      ),
      onRetry: () => retries++,
    )));

    // The reason renders without the sidecar's internal "failed:" prefix.
    expect(find.textContaining('failed:'), findsNothing);
    expect(find.textContaining('Couldn\'t reach the map-data service'), findsOneWidget);

    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('a still-loading capability shows no retry affordance', (tester) async {
    await tester.pumpWidget(_host(CapabilityWarmingNotice(
      capabilityLabel: 'Routing',
      status: const CapabilityStatus(
        ready: false,
        reason: 'building graph',
        progress: 0.3,
        etaS: 90,
      ),
      onRetry: () {},
    )));

    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('no onRetry wired: a failure still renders, just without the button', (tester) async {
    await tester.pumpWidget(_host(const CapabilityWarmingNotice(
      capabilityLabel: 'Routing',
      status: CapabilityStatus(ready: false, reason: 'failed:boom'),
    )));

    expect(find.text('Try again'), findsNothing);
    expect(find.textContaining('Routing unavailable'), findsOneWidget);
  });
}

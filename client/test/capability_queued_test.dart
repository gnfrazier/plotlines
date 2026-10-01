// Issue #573 — a region queued to build (the sidecar's bare
// `{"ready": false, "reason": "pending"}`, no `progress`) read as
// `CapabilityStatus.failed`: Pi QA of #522 saw the "Routing is unavailable"
// card with Try again, and "Routing unavailable — pending", for the moments
// before it turned into the honest "Routing loading — building graph".
// A queued build is a wait.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/presentation/widgets/error_states.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

const _queuedJson = {'ready': false, 'reason': 'pending'};

void main() {
  test('the sidecar\'s queued answer is a wait, not a failure', () {
    final status = CapabilityStatus.fromJson(_queuedJson);
    expect(status.queued, isTrue);
    expect(status.failed, isFalse);
    expect(status.describe('Routing'), 'Routing loading — waiting its turn to start');
  });

  test('a settled failure with no progress still reads as failed', () {
    final status = CapabilityStatus.fromJson({'ready': false, 'reason': 'failed:disk full'});
    expect(status.queued, isFalse);
    expect(status.failed, isTrue);
  });

  testWidgets('a resolved region still queued shows the quiet notice, not the error card',
      (tester) async {
    var retries = 0;
    final status = routingCapabilityForRegion(
      const TripRegionResolved('region-1'),
      CapabilityStatus.fromJson(_queuedJson),
    );
    await tester.pumpWidget(MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(
        body: Center(
          child: CapabilityWarmingNotice(
            capabilityLabel: 'Routing',
            status: status,
            onRetry: () => retries++,
          ),
        ),
      ),
    ));

    expect(find.text('Try again'), findsNothing);
    expect(find.textContaining('unavailable'), findsNothing);
    expect(find.textContaining('pending'), findsNothing);
    expect(find.text('Routing loading — waiting its turn to start'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
  });
}

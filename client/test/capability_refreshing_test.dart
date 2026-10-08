// Epic #641 (ARCH D73, story #649) — a trip whose held map data is past its
// time to live opens at once while the sidecar refreshes it in the
// background. `/health` says `ready: true` plus `refreshing: true`; the
// client shows a quiet status line, never the M13 error card or a retry,
// and the line clears on its own when the refresh lands.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/presentation/widgets/error_states.dart';

Widget _host(Widget child) => MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(body: Center(child: SizedBox(width: 480, child: child))),
    );

void main() {
  test('refreshing parses as ready, and is never a failure or a wait', () {
    final s = CapabilityStatus.fromJson({'ready': true, 'refreshing': true});
    expect(s.ready, isTrue);
    expect(s.refreshing, isTrue);
    expect(s.failed, isFalse);
    expect(s.pendingUpstream, isFalse);
    expect(s.describe('Routing'), contains('Refreshing the map data'));
    expect(CapabilityStatus.fromJson({'ready': true}).refreshing, isFalse);
  });

  testWidgets('the refreshing line shows, with no error card or retry, and clears',
      (tester) async {
    final status = ValueNotifier(CapabilityStatus.fromJson({'ready': true, 'refreshing': true}));
    await tester.pumpWidget(_host(ValueListenableBuilder<CapabilityStatus>(
      valueListenable: status,
      builder: (_, s, _) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('route controls'),
        if (s.refreshing)
          CapabilityWarmingNotice(capabilityLabel: 'Routing', status: s, onRetry: () {}),
      ]),
    )));
    expect(find.byKey(const ValueKey('capability-refreshing')), findsOneWidget);
    expect(find.textContaining('Refreshing the map data'), findsOneWidget);
    expect(find.text('route controls'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.textContaining('unavailable'), findsNothing);

    // The next `/health` poll after the refresh lands — nothing tapped.
    status.value = CapabilityStatus.fromJson({'ready': true});
    await tester.pump();
    expect(find.byKey(const ValueKey('capability-refreshing')), findsNothing);
    expect(find.text('route controls'), findsOneWidget);
  });
}

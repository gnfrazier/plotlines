// Issue #324 — the panel that runs the alternate gesture on the Route tab,
// and the two marks it puts on the map.
//
// What matters here is that the panel never leaves the Author holding a
// disabled button with no explanation: at every stage it says what to tap
// next, and once the divergence is drawn it says what was drawn before the
// naming dialog asks for anything.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/map/alternate_markers.dart';
import 'package:plotlines_client/presentation/widgets/alternate_draft_bar.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

Future<void> _pumpBar(
  WidgetTester tester,
  AlternateDraft draft, {
  VoidCallback? onUndo,
  VoidCallback? onCreate,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(
        body: AlternateDraftBar(
          draft: draft,
          displayFormat: const DisplayFormat(), // kilometres / metres
          onUndo: onUndo,
          onCancel: () {},
          onCreate: onCreate,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('an empty draft asks for the fork', (tester) async {
    await _pumpBar(tester, AlternateDraft.on(_route));
    expect(find.text('Tap the route where this path leaves it.'), findsOneWidget);
  });

  testWidgets('with a fork placed it asks for the rejoin and states where it leaves',
      (tester) async {
    final draft = AlternateDraft.on(_route).tap(const [-105.3, 40.0]);
    await _pumpBar(tester, draft);
    expect(find.text('Tap the route where this path comes back.'), findsOneWidget);
    expect(find.text('LEAVES 8.5 KM'), findsOneWidget);
    expect(find.textContaining('REJOINS'), findsNothing);
  });

  testWidgets('a complete draft reports the divergence and offers to create it',
      (tester) async {
    var created = false;
    final draft = AlternateDraft.on(_route)
        .tap(const [-105.3, 40.0])
        .tap(const [-105.1, 40.0])
        .tap(const [-105.2, 40.1]);
    await _pumpBar(tester, draft, onCreate: () => created = true);

    expect(find.text('Tap to shape the path, or create it as it is.'), findsOneWidget);
    expect(find.text('LEAVES 8.5 KM'), findsOneWidget);
    expect(find.text('REJOINS 25.6 KM'), findsOneWidget);
    // The difference against the day, signed — a detour north of a straight
    // route is longer than what it replaces.
    expect(find.textContaining('+'), findsOneWidget);

    await tester.tap(find.text('Create alternate'));
    await tester.pumpAndSettle();
    expect(created, isTrue);
  });

  testWidgets('Create is unavailable while the draft is blocked, and the panel says why',
      (tester) async {
    // Fork and rejoin on the same point: a divergence with nowhere to go.
    final draft = AlternateDraft.on(_route)
        .tap(const [-105.2, 40.0])
        .tap(const [-105.2, 40.0]);
    await _pumpBar(tester, draft);

    expect(find.text('The fork and the rejoin are the same point on the route.'),
        findsOneWidget);
    final create = tester.widget<PlotButton>(
      find.widgetWithText(PlotButton, 'Create alternate'),
    );
    expect(create.onPressed, isNull);
  });

  testWidgets('the fork and rejoin marks paint at a range of sizes', (tester) async {
    for (final endpoint in AlternateEndpoint.values) {
      for (final size in const [12.0, 26.0, 64.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: PlotTheme.light(),
            home: Center(child: AlternateEndpointMarker(endpoint, size: size)),
          ),
        );
        expect(tester.takeException(), isNull,
            reason: '$endpoint at $size threw while painting');
        expect(find.byType(AlternateEndpointMarker), findsOneWidget);
      }
    }
  });
}

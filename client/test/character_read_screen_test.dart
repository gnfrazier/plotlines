// H13 (FR132, FR116) — the Character-facing "Read my trip" tab. Covers the
// plot-points section's reveal-safe rendering (a withheld plot point shows a
// placeholder, never its title or note) and the itinerary section reusing
// `buildItinerary` the same way F2's Author-facing preview does. `DayCueSection`
// reuse and the native print/file dialogs are exercised by
// `export_tab_cue_provisions_test.dart` / `itinerary_panel_widget_test.dart`
// already — not duplicated here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/character_read_screen.dart';
import 'support/display_units.dart';

Future<void> _pump(WidgetTester tester, Trip trip) async {
  final container = ProviderContainer(overrides: [metricUnits()]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: CharacterReadScreen(trip: trip)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Trip _trip({List<Anchor> anchors = const []}) => Trip(
      id: 't1',
      title: 'Test Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      anchors: anchors,
    );

void main() {
  testWidgets('no anchors: no Plot Points section at all', (tester) async {
    await _pump(tester, _trip());

    expect(find.text('PLOT POINTS'), findsNothing);
  });

  testWidgets('an always-visible narrative role shows its title and note', (tester) async {
    await _pump(
      tester,
      _trip(anchors: [
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.alwaysVisible,
            title: 'The Old Mill',
            note: 'Built in 1890.',
          ),
        ]),
      ]),
    );

    expect(find.text('PLOT POINTS'), findsOneWidget);
    expect(find.text('The Old Mill'), findsOneWidget);
    expect(find.text('Built in 1890.'), findsOneWidget);
  });

  testWidgets('an on_arrival narrative role renders "Held for arrival," never its title or note',
      (tester) async {
    await _pump(
      tester,
      _trip(anchors: [
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.onArrival,
            title: 'The Ambush Site',
            note: 'This is where it happened.',
          ),
        ]),
      ]),
    );

    expect(find.text('Held for arrival'), findsOneWidget);
    expect(find.text('The Ambush Site'), findsNothing);
    expect(find.text('This is where it happened.'), findsNothing);
  });

  testWidgets('a hazard narrative role is always visible and badged HAZARD', (tester) async {
    await _pump(
      tester,
      _trip(anchors: [
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            title: 'Loose Rock',
            note: 'Rockfall risk.',
            hazard: true,
          ),
        ]),
      ]),
    );

    expect(find.text('Loose Rock'), findsOneWidget);
    expect(find.text('HAZARD'), findsOneWidget);
  });

  testWidgets('a provision role never appears in Plot Points (narrative only)', (tester) async {
    await _pump(
      tester,
      _trip(anchors: [
        Anchor(id: 'a1', coord: const [0.0, 0.0], roles: [
          Role(id: 'r1', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible, note: 'Water.'),
        ]),
      ]),
    );

    expect(find.text('PLOT POINTS'), findsNothing);
  });
}

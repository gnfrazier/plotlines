// FR106, FR110 (Story O1) — the promotion dialog: assigning a role set to a
// hand-placed point in one interaction, and the validation that keeps an
// anchor from being created with zero roles (FR106's own invariant).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/anchor_promotion_panel.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Trip _fixtureTrip() => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    );

/// Mirrors how `trip_shell_screen.dart` hosts `ContentTab`/the panel: watch
/// `currentTripProvider` and pass the live trip down, so a promotion is
/// reflected in the next build.
class _Harness extends ConsumerWidget {
  const _Harness();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(currentTripProvider);
    return MaterialApp(home: Scaffold(body: AnchorPromotionPanel(trip: trip)));
  }
}

Future<void> _pump(WidgetTester tester) => tester.pumpWidget(
      ProviderScope(
        overrides: [currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_fixtureTrip()))],
        child: const _Harness(),
      ),
    );

void main() {
  testWidgets('shows an empty state with no anchors yet', (tester) async {
    await _pump(tester);
    expect(find.textContaining('No anchors yet'), findsOneWidget);
  });

  testWidgets('promoting a hand-placed point with two roles adds one anchor card', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Promote a place'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Independence Monument');
    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
    // RoleKind.values order is narrative, provision, station — select the
    // first two, the national-monument case (FR106).
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();

    await tester.tap(find.text('Promote'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Independence Monument'), findsOneWidget);
  });

  testWidgets('submitting with no role selected shows an error and does not promote', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Promote a place'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
    await tester.tap(find.text('Promote'));
    await tester.pump();

    expect(find.text('Assign at least one role (FR106).'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('submitting with a non-numeric coordinate shows an error', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Promote a place'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), 'nope');
    await tester.tap(find.text('Promote'));
    await tester.pump();

    expect(find.text('Latitude and longitude must both be numbers.'), findsOneWidget);
  });

  testWidgets('promoting with a role offset shows the offset on the anchor card (FR107 / O2)', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Promote a place'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Trailhead');
    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.020');
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.270');
    // RoleKind.values order is narrative, provision, station — select the
    // first (narrative), the role the overlook spur offset belongs to.
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'Offset latitude (optional)'), '40.024');
    await tester.enterText(find.widgetWithText(TextField, 'Offset longitude (optional)'), '-105.266');

    await tester.tap(find.text('Promote'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('narrative offset: 40.02400, -105.26600'), findsOneWidget);
  });

  testWidgets('an offset latitude with no longitude is rejected rather than silently dropped', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Promote a place'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Offset latitude (optional)'), '40.024');

    await tester.tap(find.text('Promote'));
    await tester.pump();

    expect(find.text('The narrative role\'s offset needs both latitude and longitude, or neither.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('promoting with roles left at their default coord adds no offset line (O2\'s AC)', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Promote a place'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();

    await tester.tap(find.text('Promote'));
    await tester.pumpAndSettle();

    expect(find.textContaining('offset:'), findsNothing);
  });

  // FR108 / O3 — Flow 3's "Role geometry: point, offset, or area."
  group('area geometry (FR108 / O3)', () {
    testWidgets('the boundary field is hidden until "this place is an area" is checked', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Boundary vertices'), findsNothing);

      // RoleKind.values contributes the first 3 checkboxes (narrative,
      // provision, station); "this place is an area" is the 4th, same
      // widget-order convention the role checkboxes above already rely on.
      final areaCheckbox = find.byType(Checkbox).at(3);
      await tester.ensureVisible(areaCheckbox);
      await tester.tap(areaCheckbox);
      // pumpAndSettle, not pump: the boundary field's live preview map kicks
      // off asset-loading futures that must resolve before the test ends.
      await tester.pumpAndSettle();

      expect(find.textContaining('Boundary vertices'), findsOneWidget);
    });

    testWidgets('promoting an anchor with a boundary shows its area on the card', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Main Street');
      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.015');
      await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.275');
      await tester.tap(find.byType(Checkbox).at(0)); // narrative role
      await tester.pump();

      // RoleKind.values contributes the first 3 checkboxes (narrative,
      // provision, station); "this place is an area" is the 4th, same
      // widget-order convention the role checkboxes above already rely on.
      final areaCheckbox = find.byType(Checkbox).at(3);
      await tester.ensureVisible(areaCheckbox);
      await tester.tap(areaCheckbox);
      await tester.pump();
      final boundaryField = find.widgetWithText(TextField, 'Boundary vertices — one "lat, lon" per line (3+)');
      await tester.ensureVisible(boundaryField);
      await tester.enterText(
        boundaryField,
        '40.01, -105.28\n40.01, -105.27\n40.02, -105.27\n40.02, -105.28',
      );
      await tester.pump();

      await tester.tap(find.text('Promote'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Main Street'), findsOneWidget);
      // 4 authored vertices, ring auto-closed to 5 points including the
      // repeat — the card reports the Author-facing count, not the closed
      // ring's raw length.
      expect(find.textContaining('Area · 4-point boundary'), findsOneWidget);
    });

    testWidgets('checking "area" without giving 3 vertices shows an error and does not promote', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
      await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();

      // RoleKind.values contributes the first 3 checkboxes (narrative,
      // provision, station); "this place is an area" is the 4th, same
      // widget-order convention the role checkboxes above already rely on.
      final areaCheckbox = find.byType(Checkbox).at(3);
      await tester.ensureVisible(areaCheckbox);
      await tester.tap(areaCheckbox);
      await tester.pump();
      final boundaryField = find.widgetWithText(TextField, 'Boundary vertices — one "lat, lon" per line (3+)');
      await tester.ensureVisible(boundaryField);
      await tester.enterText(boundaryField, '40.01, -105.28\n40.02, -105.27');
      await tester.pump();

      await tester.tap(find.text('Promote'));
      await tester.pump();

      expect(find.text('An area needs at least 3 boundary vertices.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('leaving "area" unchecked promotes a plain point anchor with no area card section', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
      await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();

      await tester.tap(find.text('Promote'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Area ·'), findsNothing);
    });
  });

  // FR114, FR115 / O5 — reveal defaults and the hazard hard constraint.
  group('reveal policy (FR114, FR115 / O5)', () {
    testWidgets('checking the provision role defaults its reveal to always visible, not "decide later"', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      // RoleKind.values order is narrative, provision, station — index 1 is provision.
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();

      expect(find.text('Always visible'), findsOneWidget);
    });

    testWidgets('checking the narrative role leaves its reveal at "decide later" — no engine default', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox).at(0)); // narrative
      await tester.pump();

      expect(find.text('Reveal: decide later'), findsOneWidget);
    });

    testWidgets('turning on the hazard switch replaces the reveal dropdown with a locked always-visible notice', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox).at(0)); // narrative
      await tester.pump();
      expect(find.byType(DropdownButton<RevealPolicy?>), findsOneWidget);

      await tester.tap(find.byType(Switch).last); // the panel's own preview switch is also in the tree
      await tester.pump();

      expect(find.byType(DropdownButton<RevealPolicy?>), findsNothing);
      expect(find.textContaining('always visible — hazards cannot be hidden'), findsOneWidget);
    });

    testWidgets('promoting a hazard role shows the Hazard badge on the anchor card', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
      await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
      await tester.tap(find.byType(Checkbox).at(0)); // narrative
      await tester.pump();
      await tester.tap(find.byType(Switch).last); // hazard on — the panel's own preview switch is also in the tree
      await tester.pump();

      await tester.tap(find.text('Promote'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('HAZARD'), findsOneWidget);
    });
  });

  // O5's AC — "the Author can preview the trip as a Character would see it
  // before departure."
  group('preview as Character (O5 AC)', () {
    testWidgets('an on_arrival narrative role is hidden in preview mode, an always-visible provision role is not', (tester) async {
      await _pump(tester);

      // Promote an anchor with a withheld narrative role and an always-visible provision role.
      await tester.tap(find.text('Promote a place'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '40.02');
      await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '-105.27');
      await tester.tap(find.byType(Checkbox).at(0)); // narrative
      await tester.pump();
      await tester.tap(find.text('Reveal: decide later'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('On arrival').last);
      await tester.pump();
      await tester.tap(find.byType(Checkbox).at(1)); // provision — defaults always visible
      await tester.pump();
      await tester.tap(find.text('Promote'));
      await tester.pumpAndSettle();

      // Author-editing view shows both role chips plainly.
      expect(find.text('narrative'), findsOneWidget);
      expect(find.text('provision'), findsOneWidget);

      // Flip on the Character preview.
      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(find.text('narrative · hidden'), findsOneWidget);
      expect(find.text('provision'), findsOneWidget);
      // The remove-anchor affordance is an Author-only action, not part of what a Character sees.
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });
}

// Issue #230 B3/B4/B5/B6/C3 — the New Route panel.
//
// The reviewed screenshot (`client/design/screens/trip-definition.png`,
// `bug-for-endpoint.png`) carried five distinct defects on one surface: two
// mode selectors with the same vocabulary and nothing distinguishing them, an
// overflow menu that covered the form beneath it, an unbuilt GPX import
// offered as a choice in the primary path, requirement ids in user copy, and
// a routing failure printed as a Python traceback under START / END / VIA.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/presentation/screens/new_route_screen.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/settings_provider.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// The map layer leaves a ticker a single `pump()` does not settle — the
/// same short-pump loop the other map-bearing screen tests use.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  AsyncValue<String?>? region,
}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final router = GoRouter(
    initialLocation: '/new',
    routes: [
      GoRoute(path: '/new', builder: (_, _) => const NewRouteScreen()),
      GoRoute(path: '/plan', builder: (_, _) => const SizedBox.shrink()),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      // No bbox: `tripRegionKeyProvider` resolves to null, which is the
      // honest "draw the trip area first" not-ready, not a failure.
      if (region != null) tripRegionKeyProvider.overrideWith((ref) => region.value),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await _settle(tester);
}

void main() {
  testWidgets('the two mode selectors are named for their scope and say what they do',
      (tester) async {
    // B5 — `PRIMARY MODES · pick any` and `MODE` used the same vocabulary
    // with nothing on screen explaining how they differ or interact.
    await _pumpPanel(tester);

    expect(find.text('PRIMARY MODES · pick any'), findsNothing);
    expect(find.text('TRIP MODES'), findsOneWidget);
    expect(find.text('MODE FOR THIS ROUTE'), findsOneWidget);
    expect(find.textContaining('which map layers switch on'), findsOneWidget);
    expect(find.textContaining('Which mode this first route is solved for'), findsOneWidget);
  });

  testWidgets('the trip-mode overflow pushes the form down instead of covering it',
      (tester) async {
    // B5 — this was a `PopupMenuButton`; its menu sat on top of the days and
    // party-size fields, hiding their labels while open.
    await _pumpPanel(tester);

    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.text('More modes'), findsOneWidget);

    final beforeDates = tester.getRect(find.text('DATES'));
    await tester.tap(find.text('More modes'));
    await tester.pump();

    // The extra modes appear, and DATES moved *down* rather than being
    // covered — it is still hit-testable at its new position.
    expect(find.text('Transit'), findsOneWidget);
    expect(tester.getRect(find.text('DATES')).top, greaterThan(beforeDates.top));
  });

  testWidgets('no unbuilt capability is offered in the primary path', (tester) async {
    // B6 — "Import a GPX track — Not built yet" was a greyed radio option in
    // the main flow. Flow 8 reserves disabled-with-a-reason for a capability
    // that is coming back.
    await _pumpPanel(tester);

    expect(find.textContaining('GPX'), findsNothing);
    expect(find.textContaining('Not built yet'), findsNothing);
    expect(find.text('Blank canvas'), findsOneWidget);
    expect(find.text('Generate from a theme'), findsOneWidget);
  });

  testWidgets('no requirement ids appear in user copy', (tester) async {
    // B4 — "Honoured as an envelope (FR8)" and "up to two via-nodes (A9)"
    // read as error codes to anyone outside the project.
    await _pumpPanel(tester);

    expect(find.textContaining('(FR8)'), findsNothing);
    expect(find.textContaining('(A9'), findsNothing);
    expect(find.textContaining('Honoured as an envelope'), findsOneWidget);
    expect(find.textContaining('up to two via-nodes'), findsOneWidget);
  });

  testWidgets('the target-distance field reads the units preference', (tester) async {
    // C1/C3 — the label said `(km)` on a screen whose extent readout said
    // `MI`, and marked the requirement with a text suffix inside the label.
    await _pumpPanel(tester);

    expect(find.textContaining('Target distance (km)'), findsNothing);
    expect(find.text('Target distance'), findsOneWidget);
    // The default under a US locale is miles; either way the suffix is the
    // preference's own unit, never a hardcoded one.
    final container = ProviderScope.containerOf(
        tester.element(find.byType(NewRouteScreen)),
        listen: false);
    final expected = container.read(settingsProvider).unit == DistanceUnit.miles ? 'mi' : 'km';
    expect(find.text(expected), findsOneWidget);
    expect(find.textContaining('Required — a loop has no destination'), findsOneWidget);
  });

  testWidgets('a not-ready routing capability states its reason under its own heading',
      (tester) async {
    // B3 — the notice was anchored beneath START / END / VIA, so it read as
    // a validation error on that field rather than a surface-level failure.
    await _pumpPanel(tester);

    expect(find.text('ROUTING'), findsOneWidget);
    expect(find.textContaining('draw the trip area before routing is available'),
        findsOneWidget);
  });

  testWidgets('a disabled Generate is never silent, and never gives two reasons at once',
      (tester) async {
    // Flow 8 / FR121 — "disabled and says so". With no trip area drawn, the
    // reason is the routing block above it; the start-point hint would be a
    // second, competing answer to the same question, so it waits until
    // routing is the thing that is ready.
    await _pumpPanel(tester);

    final generate = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Generate route'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(generate.onPressed, isNull);
    expect(find.textContaining('draw the trip area before routing is available'),
        findsOneWidget);
    expect(find.textContaining('place a start point'), findsNothing);
  });
}

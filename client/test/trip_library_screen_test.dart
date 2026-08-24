// A10 (PRD FR96) — cold start shows the shipped home region rather than a
// blank/iconic placeholder, and "New trip" always prompts for a location
// (prefilled with the last-used value) instead of gating behind a one-time
// first-run dialog. Sidecar/DB are faked the same way widget_test.dart and
// trip_shell_screen_test.dart already do, so this only exercises the
// library screen's own logic, not a real generate/save flow.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/home_region.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:plotlines_client/presentation/screens/trip_library_screen.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// The empty-library map preview drags in flutter_map/vector_map_tiles,
/// which (like trip_shell_screen_test.dart's map-bearing tabs) leaves a
/// ticker that a single `pump()` doesn't fully settle — several short pumps
/// clear it without the hang a `pumpAndSettle()` risks on that same ticker.
Future<void> _settleMap(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _harness(AppDatabase db, {GoRouter? router}) {
  final effectiveRouter = router ??
      GoRouter(
        initialLocation: '/',
        routes: [GoRoute(path: '/', builder: (_, _) => const TripLibraryScreen())],
      );
  return ProviderScope(
    overrides: [
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      appDatabaseProvider.overrideWithValue(db),
    ],
    child: MaterialApp.router(routerConfig: effectiveRouter),
  );
}

void main() {
  testWidgets('cold start shows the shipped home region, not a blocking dialog', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(_harness(db));
    await _settleMap(tester);

    expect(find.text('No trips yet'), findsOneWidget);
    expect(find.byType(TapToPickMap), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('New trip prompts for a location, prefilled with the last-used value',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.setSetting('last_trip_location', 'Asheville, NC');
    await tester.pumpWidget(_harness(db));
    await _settleMap(tester);

    await tester.tap(find.text('New trip'));
    await tester.pump();

    expect(find.text('Where are we going?'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Asheville, NC');
  });

  testWidgets(
      'choosing the home region persists it and proceeds to N1\'s trip-extent step',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    List<double>? capturedExtra;
    var pushed = false;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const TripLibraryScreen()),
        GoRoute(
          path: '/new-trip-area',
          builder: (_, state) {
            pushed = true;
            capturedExtra = state.extra as List<double>?;
            return const SizedBox.shrink();
          },
        ),
      ],
    );
    await tester.pumpWidget(_harness(db, router: router));
    await _settleMap(tester);

    await tester.tap(find.text('New trip'));
    await tester.pump();
    await tester.tap(find.text('Use ${HomeRegion.label}'));
    await _settleMap(tester);

    expect(pushed, isTrue);
    expect(capturedExtra, isNull);
    expect(await db.getSetting('last_trip_location'), HomeRegion.label);
  });

  testWidgets('cancelling the location prompt does not start a trip', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    var pushed = false;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const TripLibraryScreen()),
        GoRoute(path: '/new-trip-area', builder: (_, _) {
          pushed = true;
          return const SizedBox.shrink();
        }),
      ],
    );
    await tester.pumpWidget(_harness(db, router: router));
    await _settleMap(tester);

    await tester.tap(find.text('New trip'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await _settleMap(tester);

    expect(pushed, isFalse);
    expect(await db.getSetting('last_trip_location'), isNull);
  });
}

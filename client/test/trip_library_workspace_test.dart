// G2 (PRD FR74 / FR76) — the portfolio workspace built on top of G2a's floor:
// cards carry distance / elevation / day count / group size and a sync badge,
// the collection filters by mode and by duration, and each card has an
// actions menu (Edit route / Manage roster & preferences / Export backup /
// Clone). Seeds real rows so the grid renders rather than the cold-start map.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plotlines_client/presentation/screens/trip_library_screen.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Widget _harness(AppDatabase db) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const TripLibraryScreen()),
      GoRoute(path: '/plan', builder: (_, _) => const Scaffold(body: Text('PLAN'))),
      GoRoute(path: '/settings', builder: (_, _) => const Scaffold(body: Text('SETTINGS'))),
    ],
  );
  return ProviderScope(
    overrides: [
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      appDatabaseProvider.overrideWithValue(db),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<AppDatabase> _seed() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  await db.saveTrip(
    id: 'ride',
    title: 'Pisgah Gravel Loop',
    modes: const ['cycling'],
    declaredModes: const ['cycling'],
    payloadJson: '{}',
    summaryJson: '{"distance_m":58000,"ascent_m":1200,"day_count":1,"group_size":4}',
    updatedAt: DateTime.utc(2026, 8, 27),
  );
  await db.saveTrip(
    id: 'hike',
    title: 'Black Mountain Crest',
    modes: const ['hiking'],
    declaredModes: const ['hiking'],
    payloadJson: '{}',
    summaryJson: '{"distance_m":40000,"ascent_m":3000,"day_count":4,"group_size":2}',
    updatedAt: DateTime.utc(2026, 8, 25),
  );
  return db;
}

void main() {
  testWidgets('cards show distance / elevation / day count / group size + sync badge',
      (tester) async {
    final db = await _seed();
    addTearDown(db.close);
    await tester.pumpWidget(_harness(db));
    await tester.pumpAndSettle();

    expect(find.text('Pisgah Gravel Loop'), findsOneWidget);
    expect(find.textContaining('58 KM'), findsOneWidget);
    expect(find.textContaining('↑ 1200 M'), findsOneWidget);
    expect(find.textContaining('4 IN GROUP'), findsOneWidget);
    expect(find.textContaining('1 DAY'), findsOneWidget);
    // FR76 — single-device build: every trip badges as This device
    // (PlotBadge renders the label upper-cased).
    expect(find.text('THIS DEVICE'), findsWidgets);
  });

  testWidgets('filter by mode narrows the grid', (tester) async {
    final db = await _seed();
    addTearDown(db.close);
    await tester.pumpWidget(_harness(db));
    await tester.pumpAndSettle();

    expect(find.text('Black Mountain Crest'), findsOneWidget);
    // 'CYCLING' also appears as a card mode tag — tap the filter chip.
    await tester.tap(find.widgetWithText(FilterChip, 'CYCLING'));
    await tester.pumpAndSettle();

    expect(find.text('Pisgah Gravel Loop'), findsOneWidget);
    expect(find.text('Black Mountain Crest'), findsNothing);
  });

  testWidgets('filter by duration narrows the grid', (tester) async {
    final db = await _seed();
    addTearDown(db.close);
    await tester.pumpWidget(_harness(db));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Multi-day'));
    await tester.pumpAndSettle();

    expect(find.text('Black Mountain Crest'), findsOneWidget); // 4 days
    expect(find.text('Pisgah Gravel Loop'), findsNothing); // 1 day
  });

  testWidgets('the per-card menu offers the FR74 actions and Clone opens the scope picker',
      (tester) async {
    final db = await _seed();
    addTearDown(db.close);
    await tester.pumpWidget(_harness(db));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();

    expect(find.text('Edit route'), findsOneWidget);
    expect(find.text('Manage roster & preferences'), findsOneWidget);
    expect(find.text('Export backup'), findsOneWidget);
    expect(find.text('Clone…'), findsOneWidget);
    expect(find.text('Delete…'), findsOneWidget);

    await tester.tap(find.text('Clone…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Clone "'), findsOneWidget);
    expect(find.text('CARRIES'), findsOneWidget);
    expect(find.text('DOES NOT CARRY'), findsOneWidget);
  });
}

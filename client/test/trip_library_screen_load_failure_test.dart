// Issue #390 — #317's closing comment flagged the identical defect at
// `trip_library_screen.dart:146`: the caught error from `tripLibraryProvider`
// was interpolated straight into a `Text`, whose `toString()` is a raw
// drift/sqlite3 exception. #317 routed the Layers tab's equivalent failure
// through `DesktopErrorSurface`, but that surface is driven by M13's typed
// state enum, pinned to exactly twelve values by `desktop_error_state_test`
// — none of which is "the local trip database didn't open." So this is a
// purpose-built treatment (`_LibraryLoadFailed`) in the same what/why/retry
// shape instead, exercised here the same way
// `layers_catalog_error_surface_test.dart` exercises the Layers tab's fix.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart' show TripListEntry;
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/presentation/screens/trip_library_screen.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_library_provider.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// Fails `tripLibraryProvider` with the raw shape a drift/sqlite3 read
/// failure actually takes, until [heal] is called.
class _FlakyTripLibrary {
  bool healthy = false;
  int calls = 0;

  void heal() => healthy = true;

  Future<List<TripListEntry>> list() async {
    calls++;
    if (!healthy) {
      throw StateError('SqliteException(14): unable to open database file');
    }
    return const [];
  }
}

Widget _harness(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [GoRoute(path: '/', builder: (_, _) => const TripLibraryScreen())],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

ProviderContainer _container(_FlakyTripLibrary lib) {
  final c = ProviderContainer(
    overrides: [
      sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
      tripLibraryProvider.overrideWith((ref) => lib.list()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  testWidgets('a trip-library read failure renders a purpose-built retry treatment, not the raw exception',
      (tester) async {
    final lib = _FlakyTripLibrary();
    await tester.pumpWidget(_harness(_container(lib)));
    await tester.pump();

    expect(find.text('The trip library didn\'t open'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('SqliteException'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.textContaining('Couldn\'t open the local trip library'), findsNothing);
  });

  testWidgets('Retry re-runs tripLibraryProvider and recovers', (tester) async {
    final lib = _FlakyTripLibrary();
    final container = _container(lib);
    await tester.pumpWidget(_harness(container));
    await tester.pump();
    expect(lib.calls, 1);

    lib.heal();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(lib.calls, greaterThan(1), reason: 'Retry must re-run tripLibraryProvider');
    expect(find.text('The trip library didn\'t open'), findsNothing);
    expect(find.text('No trips yet'), findsOneWidget);
  });
}

// Issue #577 — no way back from a trip to the library, and no autosave: the
// manual Save was the only write, so any exit would have dropped authored
// work. While the shell is open, changes are persisted after a quiet period;
// leaving flushes what's pending; the shell has a named Library action.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/presentation/screens/trip_shell_screen.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_autosave_provider.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

ProviderContainer _container(AppDatabase db) {
  final c = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    tripAutosaveProvider.overrideWith((ref) => TripAutosave(ref, debounce: Duration.zero)),
  ]);
  addTearDown(c.dispose);
  return c;
}

/// Longer than any debounce or first-open migration the tests below see.
Future<void> _quiet() => Future<void>.delayed(const Duration(milliseconds: 200));

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('a trip not in the library yet is written once the shell starts', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final id = c.read(currentTripProvider).id;

    c.read(tripAutosaveProvider.notifier).start();
    await _until(() => c.read(tripAutosaveProvider) == AutosaveStatus.saved);

    expect(await db.loadTrip(id), isNotNull);
    expect(c.read(tripAutosaveProvider), AutosaveStatus.saved);
  });

  test('an edit is on disk without pressing Save, and survives a reopen', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    final id = c.read(currentTripProvider).id;
    await c.read(tripPersistenceProvider).save(compose: false);

    c.read(tripAutosaveProvider.notifier).start();
    c.read(currentTripProvider.notifier).renameTrip('Blue Ridge, renamed');
    await c.read(tripAutosaveProvider.notifier).stop();

    final reader = _container(db);
    await reader.read(tripPersistenceProvider).open(id);
    expect(reader.read(currentTripProvider).title, 'Blue Ridge, renamed');
  });

  test('changes outside the shell are not written', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    c.read(tripAutosaveProvider.notifier);
    final id = c.read(currentTripProvider).id;

    c.read(currentTripProvider.notifier).renameTrip('Never opened in the shell');
    await _quiet();

    expect(await db.loadTrip(id), isNull);
  });

  test('every flush waits for the last write, even one another flush started', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final writes = <Completer<void>>[];
    final c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      tripPersistenceProvider.overrideWith((ref) => _GatedPersistence(ref, writes)),
      // Long enough that only explicit flushes write in this test.
      tripAutosaveProvider.overrideWith(
          (ref) => TripAutosave(ref, debounce: const Duration(hours: 1))),
    ]);
    addTearDown(c.dispose);
    final autosave = c.read(tripAutosaveProvider.notifier);
    autosave.start();
    await _quiet();

    c.read(currentTripProvider.notifier).renameTrip('first');
    final timerFlush = autosave.flush(); // the debounce firing: write 1
    await _until(() => writes.length == 1);
    c.read(currentTripProvider.notifier).renameTrip('second'); // dirty again
    // Two callers wait on write 1 (say, the debounce's retry and the Library
    // action). The first to resume starts write 2; the second must then wait
    // for it rather than find nothing dirty and return.
    final otherFlush = autosave.flush();
    var leftLibrary = false;
    final libraryFlush = autosave.flush().then((_) => leftLibrary = true);

    writes[0].complete();
    await _until(() => writes.length == 2); // the change gets its own write
    await _quiet();
    expect(leftLibrary, isFalse, reason: 'leaving must wait for the second write');

    writes[1].complete();
    await Future.wait([timerFlush, libraryFlush, otherFlush]);
    expect(leftLibrary, isTrue);
    expect(writes, hasLength(2));
  });

  test('a failed write is reported once, never thrown at a flush waiting on it', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final writes = <Completer<void>>[];
    final c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      tripPersistenceProvider.overrideWith((ref) => _GatedPersistence(ref, writes)),
      tripAutosaveProvider.overrideWith(
          (ref) => TripAutosave(ref, debounce: const Duration(hours: 1))),
    ]);
    addTearDown(c.dispose);
    final autosave = c.read(tripAutosaveProvider.notifier);
    autosave.start();
    await _quiet();

    c.read(currentTripProvider.notifier).renameTrip('edit');
    final owner = autosave.flush();
    await _until(() => writes.length == 1);
    final waiter = autosave.flush(); // the Library action, mid-write
    writes[0].completeError(StateError('disk full'));

    await owner;
    // The waiter finds the change still unsaved and tries it again; that
    // fails too, and the waiter still completes normally — the indicator
    // carries the failure, never an exception at the Library action.
    await _until(() => writes.length == 2);
    writes[1].completeError(StateError('disk full'));
    await waiter;
    expect(c.read(tripAutosaveProvider), AutosaveStatus.failed);
  });

  // The write itself is the unit tests' above (a widget test can't run real
  // drift I/O alongside the map's tile isolates); this pins the shell's half:
  // a new trip, arrived by `go('/plan')`, has a Library action, and it
  // flushes autosave before it navigates.
  testWidgets('a new trip offers Library, which flushes autosave before it leaves',
      (tester) async {
    final log = <String>[];
    final router = GoRouter(
      initialLocation: '/plan',
      routes: [
        GoRoute(
            path: '/',
            builder: (_, _) {
              log.add('library');
              return const Scaffold(body: Text('LIBRARY'));
            }),
        GoRoute(path: '/plan', builder: (_, _) => const TripShellScreen()),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
        appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
        tripAutosaveProvider.overrideWith((ref) => _RecordingAutosave(ref, log)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    expect(log, ['start']);

    await tester.tap(find.text('Library'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('LIBRARY'), findsOneWidget);
    // Flushed before the library was built — leaving never races the write.
    expect(log.take(3), ['start', 'flush', 'library']);
  });
}

class _RecordingAutosave extends TripAutosave {
  _RecordingAutosave(super.ref, this.log);
  final List<String> log;

  @override
  void start() => log.add('start');
  @override
  Future<void> flush() async => log.add('flush');
  @override
  Future<void> stop() async => log.add('stop');
}

/// Each autosave write waits on a completer the test controls.
class _GatedPersistence extends TripPersistence {
  _GatedPersistence(super.ref, this.writes);
  final List<Completer<void>> writes;

  @override
  Future<void> save({bool compose = true}) {
    final gate = Completer<void>();
    writes.add(gate);
    return gate.future;
  }
}

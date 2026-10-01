// FR142(a) (Story K12), Flow 10 §01 — undo in the trip shell: labelled Undo
// and Redo that name their step, Ctrl+Z / Ctrl+Y outside a text field, the
// session history with its stated depth and limits, and the history cleared
// when the Author leaves the trip for the library. Also FR142(b)'s stale-list
// path from the app bar.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/trip_shell_screen.dart';
import 'package:plotlines_client/presentation/widgets/undo_controls.dart';
import 'package:plotlines_client/state/authoring_undo_provider.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_autosave_provider.dart';
import 'support/display_units.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// Autosave's own writes are `trip_autosave_test.dart`'s; a widget test can't
/// run real drift I/O beside the map's tile isolates.
class _QuietAutosave extends TripAutosave {
  _QuietAutosave(super.ref);
  @override
  void start() {}
  @override
  Future<void> flush() async {}
  @override
  Future<void> stop() async {}
}

Trip _trip({bool stale = false}) => Trip(
      id: 'trip-1',
      title: 'Test Loop',
      createdAt: '2026-08-17T00:00:00Z',
      updatedAt: '2026-08-17T00:00:00Z',
      modes: const {'cycling'},
      days: [
        Day(id: 'day-1', index: 1, segments: [
          Segment(
            id: 'seg-1',
            mode: 'cycling',
            shape: 'point_to_point',
            start: const [-105.27, 40.02],
            end: const [-105.2, 40.05],
            geometry: LineString(coordinates: const [
              [-105.27, 40.02],
              [-105.2, 40.05],
            ]),
            solve: SolveProvenance(solvedAt: '2026-08-17T00:00:00Z', stale: stale),
          ),
        ]),
      ],
    );

/// The map's ticker never settles; a few short pumps carry a frame through.
Future<void> _pumps(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ProviderContainer> _pumpShell(WidgetTester tester, {bool stale = false}) async {
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(overrides: [
    metricUnits(),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
    appDatabaseProvider.overrideWithValue(db),
    selectedSegmentProvider.overrideWith((ref) => ('day-1', 'seg-1')),
    tripAutosaveProvider.overrideWith((ref) => _QuietAutosave(ref)),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(_trip(stale: stale));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/plan',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('LIBRARY'))),
          GoRoute(path: '/plan', builder: (_, _) => const TripShellScreen()),
        ],
      ),
    ),
  ));
  await _pumps(tester);
  return container;
}

String _title(ProviderContainer c) => c.read(currentTripProvider).title;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  testWidgets('Undo and Redo name their step and move the trip between states', (tester) async {
    final container = await _pumpShell(tester);
    final undoButton = find.byKey(const ValueKey('undo-button'));
    expect(tester.widget<TextButton>(undoButton).onPressed, isNull);
    expect(find.byTooltip('Nothing to undo'), findsOneWidget);

    container.read(currentTripProvider.notifier).renameTrip('Black Mountains');
    await tester.pump();
    expect(find.byTooltip('Undo: Rename the trip'), findsOneWidget);

    await tester.tap(undoButton);
    await tester.pump();
    expect(_title(container), 'Test Loop');
    expect(find.text('Test Loop'), findsOneWidget);
    expect(find.byTooltip('Redo: Rename the trip'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('redo-button')));
    await tester.pump();
    expect(_title(container), 'Black Mountains');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z act on the trip history', (tester) async {
    final container = await _pumpShell(tester);
    container.read(currentTripProvider.notifier).renameTrip('Black Mountains');
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.keyZ);
    expect(_title(container), 'Test Loop');
    await _press(tester, LogicalKeyboardKey.keyY);
    expect(_title(container), 'Black Mountains');
    await _press(tester, LogicalKeyboardKey.keyZ);
    await _press(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(_title(container), 'Black Mountains');
  });

  testWidgets("Ctrl+Z in a text field over the shell stays the field's own", (tester) async {
    final container = await _pumpShell(tester);
    container.read(currentTripProvider.notifier).renameTrip('Black Mountains');
    await tester.pump();

    // The rename dialog's field takes focus; the shell is no longer the
    // current route and a text field holds focus — neither may undo the trip.
    await tester.tap(find.text('Black Mountains'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.keyZ);
    expect(_title(container), 'Black Mountains');
  });

  testWidgets('the history menu lists the session and states its limits', (tester) async {
    final container = await _pumpShell(tester);
    container.read(currentTripProvider.notifier).renameTrip('Black Mountains');
    await tester.pump();
    container.read(currentTripProvider.notifier).addBlankDay(kind: 'rest');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('undo-history')));
    await tester.pumpAndSettle();
    expect(find.text('THIS SESSION · 2 STEPS · UP TO $undoHistoryDepth'), findsOneWidget);
    expect(find.text('Add a rest day'), findsOneWidget);
    expect(find.text('Rename the trip'), findsOneWidget);
    expect(find.text(undoSessionNotice), findsOneWidget);
    expect(find.text(undoDerivedNotice), findsOneWidget);
    expect(find.text(undoNotesNotice), findsOneWidget);
  });

  testWidgets('leaving for the library closes the session: the history is cleared',
      (tester) async {
    final container = await _pumpShell(tester);
    container.read(currentTripProvider.notifier).renameTrip('Black Mountains');
    await tester.pump();
    expect(container.read(authoringUndoProvider).canUndo, isTrue);

    await tester.tap(find.text('Library'));
    await _pumps(tester);
    expect(find.text('LIBRARY'), findsOneWidget);
    expect(container.read(authoringUndoProvider).canUndo, isFalse);
    expect(container.read(authoringUndoProvider).canRedo, isFalse);
  });

  testWidgets('a stale passage puts a count in the app bar that opens the stale list (FR142b)',
      (tester) async {
    await _pumpShell(tester, stale: true);
    await tester.tap(find.byKey(const ValueKey('stale-count')));
    await _pumps(tester);
    expect(find.text('1 stale item needs re-solving'), findsOneWidget);
  });
}

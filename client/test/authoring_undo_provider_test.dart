// FR142(a) (Story K12) — undo/redo over everything an Author authors in the
// open trip, through the real notifiers: the payload, the trip's mode set,
// the roster layer and the bbox; one step per action however many mutators
// it calls; Author-note deletion never undone; derived work never a step;
// the history cleared when the trip is closed or another is opened.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/authoring_undo_provider.dart';
import 'package:plotlines_client/state/current_roster_provider.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

Trip _trip() => Trip(
      id: 't1',
      title: 'Blue Ridge',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1)],
      modes: const {'cycling'},
    );

/// One Author gesture per event-loop turn, as in the app: the controller
/// groups everything in a synchronous turn into one step.
Future<void> _nextGesture() => Future<void>.delayed(Duration.zero);

void main() {
  late ProviderContainer container;
  CurrentTripNotifier trip() => container.read(currentTripProvider.notifier);
  CurrentRosterNotifier roster() => container.read(currentRosterProvider.notifier);
  AuthoringUndoController undo() => container.read(authoringUndoProvider.notifier);
  UndoStatus status() => container.read(authoringUndoProvider);

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    trip().open(_trip());
  });

  test('an edit is one labelled step; undo and redo move the trip between states', () async {
    trip().renameTrip('Black Mountains');
    await _nextGesture();
    expect(status().undoLabel, 'Rename the trip');

    undo().undo();
    expect(container.read(currentTripProvider).title, 'Blue Ridge');
    expect(status().canUndo, isFalse);
    expect(status().redoLabel, 'Rename the trip');

    undo().redo();
    expect(container.read(currentTripProvider).title, 'Black Mountains');
    expect(status().canRedo, isFalse);
  });

  test('day restructuring, promotion and removal each undo to the state before them', () async {
    final dayId = trip().addBlankDay();
    await _nextGesture();
    final anchor = trip().promoteAnchor(
      coord: const [-82.5, 35.6],
      title: 'Elk Park',
      roles: [Role(id: 'r1', kind: RoleKind.narrative)],
    );
    await _nextGesture();
    trip().removeAnchor(anchor.id);
    await _nextGesture();
    expect(status().history, ['Remove an anchor', 'Promote a place', 'Add a day']);

    undo().undo();
    expect(container.read(currentTripProvider).anchors.map((a) => a.title), ['Elk Park']);
    undo().undo();
    expect(container.read(currentTripProvider).anchors, isEmpty);
    undo().undo();
    expect(container.read(currentTripProvider).days.map((d) => d.id), isNot(contains(dayId)));
  });

  test('an action that calls other mutators is still one step (setDayCount → addBlankDay)',
      () async {
    trip().setDayCount(4);
    await _nextGesture();
    expect(status().history, ['Change the day count']);
    undo().undo();
    expect(container.read(currentTripProvider).days, hasLength(1));
  });

  test('two mutators in one gesture are one step, labelled by the first', () async {
    trip().setDayTitle('d1', 'Arrival');
    trip().setDayNote('d1', 'Meet at the depot');
    await _nextGesture();
    expect(status().history, ["Edit a day's title"]);
    undo().undo();
    final day = container.read(currentTripProvider).days.single;
    expect(day.title, isNull);
    expect(day.note, isNull);
  });

  test('typing into one field is one step, not one per keystroke', () async {
    for (final text in ['M', 'Me', 'Meet', 'Meet at the depot']) {
      trip().setDayNote('d1', text);
      await _nextGesture();
    }
    expect(status().history, ["Edit a day's note"]);
    undo().undo();
    expect(container.read(currentTripProvider).days.single.note, isNull);
  });

  test('a call that changes nothing records nothing', () async {
    trip().toggleMode('cycling'); // the last mode is never removed
    roster().addEntry('ann', 'Ann');
    await _nextGesture();
    roster().addEntry('ann', 'Ann'); // idempotent
    await _nextGesture();
    expect(status().history, ['Add a Character']);
  });

  test('the trip mode set rides beside the payload and is restored with it (#319)', () async {
    trip().toggleMode('hiking');
    await _nextGesture();
    expect(container.read(currentTripProvider).modes, {'cycling', 'hiking'});
    undo().undo();
    expect(container.read(currentTripProvider).modes, {'cycling'});
    undo().redo();
    expect(container.read(currentTripProvider).modes, {'cycling', 'hiking'});
  });

  test('roster edits are undoable — membership, gear, meals', () async {
    roster().addEntry('ann', 'Ann');
    await _nextGesture();
    roster().addGearItem(GearItem(id: 'g1', label: 'Stove'));
    await _nextGesture();
    undo().undo();
    expect(container.read(currentRosterProvider).gear, isEmpty);
    undo().undo();
    expect(container.read(currentRosterProvider).entries, isEmpty);
  });

  test("Author-note deletion is never undone (FR135a): undo brings the person back, not the notes",
      () async {
    roster().open(const TripRoster(
      entries: [RosterEntry(characterId: 'dana', name: 'Dana')],
      authorNotes: [
        AuthorNote(subjectCharacterId: 'dana', body: 'Hates switchbacks', updatedAt: '2026-01-01'),
      ],
    ));
    roster().removeEntry('dana');
    await _nextGesture();
    expect(container.read(currentRosterProvider).authorNotes, isEmpty);

    undo().undo();
    final restored = container.read(currentRosterProvider);
    expect(restored.entries.map((e) => e.name), ['Dana']);
    expect(restored.authorNotes, isEmpty, reason: 'deleted notes must stay deleted');
  });

  test('a bbox revision recorded through the controller is undone with it', () async {
    const before = TripBbox(minLat: 35, minLon: -83, maxLat: 36, maxLon: -82);
    const after = TripBbox(minLat: 35, minLon: -83, maxLat: 36.5, maxLon: -81.5);
    container.read(tripBboxProvider.notifier).set(before);
    undo().edit('Change the trip area', () => container.read(tripBboxProvider.notifier).set(after));
    await _nextGesture();
    undo().undo();
    expect(container.read(tripBboxProvider), before);
    undo().redo();
    expect(container.read(tripBboxProvider), after);
  });

  test('derived work is not a step, and ends a redo branch rather than being overwritten',
      () async {
    trip().renameTrip('Black Mountains');
    await _nextGesture();
    undo().undo();
    expect(status().canRedo, isTrue);

    // A re-solve writes through the same mutators an edit uses.
    undo().derived(() => trip().setDayTitle('d1', 'Solved'));
    await _nextGesture();
    expect(status().canUndo, isFalse, reason: 'derived work is re-solved, never undone');
    expect(status().canRedo, isFalse);
    expect(container.read(currentTripProvider).days.single.title, 'Solved');
  });

  test('opening another trip, or a new one, clears the history (session-scoped)', () async {
    trip().renameTrip('Black Mountains');
    await _nextGesture();
    trip().open(_trip());
    expect(status().canUndo, isFalse);

    trip().renameTrip('Again');
    await _nextGesture();
    trip().reset();
    expect(status().canUndo, isFalse);
  });

  test('the stated depth is kept and the oldest steps drop off', () async {
    for (var i = 0; i < undoHistoryDepth + 5; i++) {
      trip().renameTrip('Name $i');
      await _nextGesture();
    }
    expect(status().history, hasLength(undoHistoryDepth));
    expect(status().depth, undoHistoryDepth);
  });
}
